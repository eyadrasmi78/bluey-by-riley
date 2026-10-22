import AppKit
import Carbon.HIToolbox
import GooglyShared

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let overlay = CursorOverlay()
    private let server = PhoneServer()
    private var statusItem: NSStatusItem!
    private lazy var host = RealtimeHost(overlay: overlay)


    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.registerBundled()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuIcon.make()
        statusItem.button?.toolTip = "Bluey"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        overlay.onFace = { [weak self] face in self?.server.send(face) }
        overlay.start()
        #if DEBUG
        showDemoBubbleIfAsked()
        #endif
        checkPermissions()
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["GOOGLY_DEMO_TRANSCRIBE"], let audio = FileManager.default.contents(atPath: path) {
            // Transcribes an audio file into a throwaway notes folder, prints the lines and quits.
            Task {
                do {
                    let result = try await MeetingNotes.transcribe(audio: audio, session: "demo0000", index: 1, sessionStarted: Date())
                    for s in result.segments { print("[\(s.start)] \(s.speaker): \(s.text)") }
                    try? FileManager.default.removeItem(at: result.folder)
                } catch { print("failed:", error) }
                exit(0)
            }
        }
        if let question = ProcessInfo.processInfo.environment["GOOGLY_DEMO_RESEARCH"] {
            host.demoResearch(question, out: ProcessInfo.processInfo.environment["GOOGLY_DEMO_OUT"] ?? "/tmp/googly-report")
        }
        #endif
        server.onPhonesChanged = { [weak self] names in
            self?.refreshIcon()
            if names.isEmpty, self?.host.awake == true { self?.host.setAwake(false) }
        }
        server.onRequest = { [weak self] packet, reply in self?.host.handle(packet, reply: reply) }
        server.start()
        host.onChange = { [weak self] in self?.refreshIcon() }

        registerHotKeys()

        if Keychain.get(.openai) == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.editKeys() }
        }
    }

    private func refreshIcon() {
        statusItem.button?.appearsDisabled = server.phoneNames.isEmpty
    }

    // MARK: Global shortcuts (user-rebindable via the Shortcuts submenu)

    private struct HotKeyDef {
        let id: String
        let title: String
        let keyCode: Int
        let modifiers: Int
    }

    private func hotKeyDefs() -> [HotKeyDef] {
        [
            HotKeyDef(id: "wake", title: "Wake Up / Follow", keyCode: kVK_Space, modifiers: optionKey),
            HotKeyDef(id: "point", title: "Point Here", keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey),
            HotKeyDef(id: "follow", title: "Follow Mouse", keyCode: kVK_ANSI_F, modifiers: controlKey | optionKey),
            HotKeyDef(id: "dock", title: "Go Home", keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey),
            HotKeyDef(id: "hide", title: "Hide / Show Cursor", keyCode: kVK_ANSI_H, modifiers: controlKey | optionKey),
            HotKeyDef(id: "talkTest", title: "Talk Test", keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey),
            HotKeyDef(id: "stop", title: "Stop Him", keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey),
        ]
    }

    private func registerHotKeys() {
        HotKeys.shared.unregisterAll()
        for def in hotKeyDefs() {
            let combo = Settings.hotkeyOverride(for: def.id) ?? (keyCode: def.keyCode, modifiers: def.modifiers)
            HotKeys.shared.register(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
                self?.performHotKey(def.id)
            }
        }
    }

    private func performHotKey(_ id: String) {
        switch id {
        case "wake": toggleAwake()
        case "point": pointHere()
        case "follow": toggleFollow()
        case "dock": overlay.goHome()
        case "hide": toggleShow()
        case "talkTest": overlay.talkTest()
        case "stop": stopActions()
        default: break
        }
    }

    private var rebindMonitor: Any?

    @objc private func rebindShortcut(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Press a New Shortcut"
        alert.informativeText = "Hold at least one of ⌃ ⌥ ⇧ ⌘ plus a key. Delete restores the default, Escape cancels."
        alert.addButton(withTitle: "Cancel")
        rebindMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return nil }
            let code = Int(event.keyCode)
            if code == kVK_Escape { NSApp.stopModal(); return nil }
            if code == kVK_Delete {
                Settings.setHotkeyOverride(for: id, nil)
                self.registerHotKeys()
                NSApp.stopModal()
                return nil
            }
            let flags = event.modifierFlags
            var mods = 0
            if flags.contains(.control) { mods |= controlKey }
            if flags.contains(.option) { mods |= optionKey }
            if flags.contains(.shift) { mods |= shiftKey }
            if flags.contains(.command) { mods |= cmdKey }
            guard mods != 0 else { return nil }
            Settings.setHotkeyOverride(for: id, (code, mods))
            self.registerHotKeys()
            NSApp.stopModal()
            return nil
        }
        alert.runModal()
        if let rebindMonitor { NSEvent.removeMonitor(rebindMonitor) }
        rebindMonitor = nil
    }

    // MARK: Actions

    @objc private func pointHere() {
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first else { return }
        overlay.mode = .pinned(CGPoint(x: m.x - screen.frame.minX, y: screen.frame.maxY - m.y))
    }

    @objc private func toggleFollow() {
        settings.followMouse.toggle()
        overlay.goHome()
    }

    @objc private func dock() { overlay.goHome() }

    #if DEBUG
    /// For checking the speech bubble's look: GOOGLY_DEMO_BUBBLE=top|middle|home shows a sample reply.
    private func showDemoBubbleIfAsked() {
        guard let where_ = ProcessInfo.processInfo.environment["GOOGLY_DEMO_BUBBLE"],
              let size = NSScreen.screens.first?.frame.size else { return }
        let y: CGFloat = where_ == "top" ? 40 : size.height * 0.55
        let thing = CGRect(x: size.width * 0.3, y: y, width: 90, height: 22)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if where_ != "home" {
                self.overlay.mode = .pinned(CGPoint(x: thing.midX, y: thing.maxY + 3))
                self.overlay.speechTargetGlobal = thing
            }
            self.overlay.view.caption = ProcessInfo.processInfo.environment["GOOGLY_DEMO_TEXT"]
                ?? "That's the prompt box, where you type to Claude. Cheeky little thing."
        }
        // GOOGLY_DEMO_OUT=path.png saves a picture of the overlay (on dark grey) and quits.
        if let out = ProcessInfo.processInfo.environment["GOOGLY_DEMO_OUT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let view = self.overlay.view
                let scale: CGFloat = 1
                let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
                ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
                ctx.fill(CGRect(x: thing.minX, y: view.bounds.height - thing.maxY, width: thing.width, height: thing.height))
                ctx.scaleBy(x: scale, y: scale)
                view.layer?.presentation()?.render(in: ctx) ?? view.layer?.render(in: ctx)
                if let image = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
        }
    }
    #endif
    @objc private func toggleShow() { settings.showCursor.toggle() }
    @objc private func toggleGlow() { settings.glow.toggle() }
    @objc private func setTrail(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let trail = PointerTrail(rawValue: raw) { settings.trail = trail }
    }
    @objc private func talkTest() { overlay.talkTest() }

    @objc private func setSize(_ item: NSMenuItem) { settings.cursorSize = Double(item.tag) }
    @objc private func setPhonePosition(_ item: NSMenuItem) { settings.phonePosition = Double(item.tag) / 100 }
    @objc private func toggleAwake() {
        server.broadcast(Packet(command: host.awake ? "sleep" : "wake"))
    }

    /// On launch, asks for whatever he still needs (so Bluey shows up in those Settings lists),
    /// and keeps a small status file so it's easy to check what's allowed.
    private func checkPermissions() {
        if settings.computerControl && !ComputerControl.isTrusted { ComputerControl.askForPermission() }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let status = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly/status.txt")
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            let text = "accessibility=\(ComputerControl.isTrusted) screenRecording=\(CGPreflightScreenCaptureAccess()) computerControl=\(Settings.shared.computerControl)\n"
            try? text.write(to: status, atomically: true, encoding: .utf8)
        }.fire()
    }

    @objc private func pairPhone() {
        NSApp.activate(ignoringOtherApps: true)
        let code = GooglySecurity.newPairingCode()
        server.beginPairing(code: code)
        let alert = NSAlert()
        alert.messageText = "Pair a Phone — \(GooglySecurity.formatPairingCode(code))"
        alert.informativeText = "On the phone, open Bluey and type this code when asked. "
            + "The code works once, for 10 minutes (or until 5 wrong tries), and only your phone will know the link key afterwards. "
            + "Every message between the devices is encrypted."
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    @objc private func unpairPhones() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Unpair all phones?"
        alert.informativeText = "Every phone will need the pairing code again to connect."
        alert.addButton(withTitle: "Unpair All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Keychain.set(.linkKey, GooglySecurity.newLinkKey().base64EncodedString())
        server.restart()
    }

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        let bundled = (try? String(contentsOf: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/commit.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/rbrown101010/bluey-by-riley/commits?sha=main&per_page=1")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        Task { @MainActor in
            let alert = NSAlert()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let latest = list.first?["sha"] as? String else { throw URLError(.cannotParseResponse) }
                if let bundled, latest == bundled {
                    alert.messageText = "Bluey is up to date"
                    alert.informativeText = "This build is the latest main (\(bundled.prefix(8)))."
                    alert.addButton(withTitle: "Nice")
                    alert.runModal()
                    return
                }
                alert.messageText = "A newer Bluey exists"
                alert.informativeText = "Latest main is \(latest.prefix(8))" + (bundled.map { "; this build is \($0.prefix(8))" } ?? "") +
                    ". Updating merges origin/main into your local copy and rebuilds the Mac app — the phone app then needs a rebuild in Xcode."
                alert.addButton(withTitle: "Run Updater in Terminal")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    // App sits at <repo>/build/Bluey.app; the updater is <repo>/scripts/update.sh.
                    let repo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                    let script = repo.appendingPathComponent("scripts/update.sh")
                    // Only run it from inside a real checkout (not, say, ~/Downloads/Bluey.app → ~/scripts).
                    guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path),
                          FileManager.default.fileExists(atPath: script.path) else {
                        let note = NSAlert()
                        note.messageText = "Can't update from here"
                        note.informativeText = "Run Bluey from its project folder's build/ directory to use the updater."
                        note.runModal()
                        return
                    }
                    if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                        try? await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: .init())
                    }
                }
            } catch {
                alert.messageText = "Couldn't check right now"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func openNotes() {
        try? FileManager.default.createDirectory(at: MeetingNotes.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(MeetingNotes.root)
    }

    @objc private func showActionLog() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "What He Did Recently"
        alert.informativeText = "Every time he clicked, typed, pressed keys, scrolled, dragged or opened something — newest first. The full log is ~/Library/Application Support/Googly/actions.log."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width]
        text.isRichText = false
        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = ActionLog.recent()
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Clear the Log")
        if alert.runModal() == .alertSecondButtonReturn { ActionLog.clear() }
    }

    @objc private func stopActions() {
        host.stopActions()
    }

    @objc private func toggleComputerControl() {
        settings.computerControl.toggle()
        if settings.computerControl && !ComputerControl.isTrusted { ComputerControl.askForPermission() }
        restartIfAwake()  // his tools change with this switch
    }

    @objc private func allowComputerControl() {
        ComputerControl.askForPermission()
        ComputerControl.openAccessibilitySettings()
    }

    /// Wakes him again so a new personality or set of tools takes effect right away.
    private func restartIfAwake() {
        guard host.awake else { return }
        server.broadcast(Packet(command: "sleep"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.server.broadcast(Packet(command: "wake")) }
    }

    @objc private func editPersonality() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "His Personality"
        alert.informativeText = "Describe who he is and how he talks. How he looks at and points at your screen stays built in."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width]
        text.isRichText = false
        text.font = NSFont.systemFont(ofSize: 13)
        text.string = RealtimeHost.personality
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset to Default")
        alert.window.initialFirstResponder = text
        switch alert.runModal() {
        case .alertFirstButtonReturn: RealtimeHost.personality = text.string
        case .alertThirdButtonReturn: RealtimeHost.personality = ""
        default: return
        }
        restartIfAwake()
    }

    @objc private func editKeys() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Saved privately on this Mac (not in the project files). The phone only ever gets short-lived keys."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = Keychain.get(.openai) == nil ? "sk-…" : "Key saved. Paste a new one to replace it."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Keychain.set(.openai, key) }
    }

    @objc private func setMood(_ item: NSMenuItem) {
        if let mood = item.representedObject as? String, let m = Mood(rawValue: mood) { settings.mood = m }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let phones = server.phoneNames
        let status = NSMenuItem(title: phones.isEmpty ? "Waiting for the phone app…" : "Phone connected: \(phones.joined(separator: ", "))",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let wake = NSMenuItem(title: host.awake ? "Go to Sleep (Follow Mode)" : "Wake Up and Talk",
                              action: #selector(toggleAwake), keyEquivalent: " ")
        wake.keyEquivalentModifierMask = [.option]
        wake.target = self
        wake.isEnabled = !phones.isEmpty
        menu.addItem(wake)
        menu.addItem(.separator())

        let control = item("Let Him Use the Computer", #selector(toggleComputerControl))
        control.state = settings.computerControl ? .on : .off
        menu.addItem(control)
        if settings.computerControl && !ComputerControl.isTrusted {
            menu.addItem(item("Allow Clicking and Typing (Accessibility)…", #selector(allowComputerControl)))
        }
        menu.addItem(item("Stop Him", #selector(stopActions), key: "s"))
        menu.addItem(item("Recent Actions…", #selector(showActionLog)))
        menu.addItem(.separator())

        let point = item("Point Here", #selector(pointHere), key: "p")
        menu.addItem(point)
        let follow = item("Eyes Follow My Mouse", #selector(toggleFollow), key: "f")
        follow.state = settings.followMouse ? .on : .off
        menu.addItem(follow)
        menu.addItem(item("Stop Pointing", #selector(dock), key: "d"))
        menu.addItem(item("Talk Test", #selector(talkTest), key: "t"))
        menu.addItem(.separator())

        let moodMenu = NSMenu()
        for mood in Mood.allCases where mood != .talking && mood != .pointing && mood != .sleepy {
            let m = item(mood.title, #selector(setMood(_:)))
            m.representedObject = mood.rawValue
            m.state = settings.mood == mood ? .on : .off
            moodMenu.addItem(m)
        }
        menu.addItem(submenu("Mood", moodMenu))

        let sizeMenu = NSMenu()
        for (name, size) in [("Small", 48), ("Medium", 72), ("Large", 96), ("Huge", 120)] {
            let s = item("\(name) (\(size) pt)", #selector(setSize(_:)))
            s.tag = size
            s.state = Int(settings.cursorSize) == size ? .on : .off
            sizeMenu.addItem(s)
        }
        menu.addItem(submenu("Cursor Size", sizeMenu))

        let phoneMenu = NSMenu()
        for (name, pos) in [("Left", 20), ("Center", 50), ("Right", 80)] {
            let p = item(name, #selector(setPhonePosition(_:)))
            p.tag = pos
            p.state = Int((settings.phonePosition * 100).rounded()) == pos ? .on : .off
            phoneMenu.addItem(p)
        }
        menu.addItem(submenu("Phone Sits Under", phoneMenu))

        menu.addItem(item("Open Meeting Notes", #selector(openNotes)))
        menu.addItem(item("Personality…", #selector(editPersonality)))
        menu.addItem(item("OpenAI Key…", #selector(editKeys)))
        menu.addItem(item("Pair a Phone…", #selector(pairPhone)))
        menu.addItem(item("Unpair All Phones…", #selector(unpairPhones)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())

        let trailMenu = NSMenu()
        for trail in PointerTrail.allCases {
            let t = item(trail.title, #selector(setTrail(_:)))
            t.representedObject = trail.rawValue
            t.state = settings.trail == trail ? .on : .off
            trailMenu.addItem(t)
        }
        menu.addItem(submenu("Pointer Trail", trailMenu))

        let glow = item("Cursor Glow", #selector(toggleGlow))
        glow.state = settings.glow ? .on : .off
        menu.addItem(glow)
        let show = item("Show Cursor", #selector(toggleShow), key: "h")
        show.state = settings.showCursor ? .on : .off
        menu.addItem(show)

        let shortcuts = NSMenu()
        for def in hotKeyDefs() {
            let combo = Settings.hotkeyOverride(for: def.id) ?? (keyCode: def.keyCode, modifiers: def.modifiers)
            let m = item("\(def.title) — \(HotKeys.describe(keyCode: combo.keyCode, modifiers: combo.modifiers))",
                         #selector(rebindShortcut(_:)))
            m.representedObject = def.id
            m.keyEquivalent = ""
            shortcuts.addItem(m)
        }
        menu.addItem(submenu("Shortcuts", shortcuts))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Bluey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Menu item that shows its global shortcut (⌃⌥ + key) when given one.
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control, .option]
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// The little blueberry blob with eyes for the menu bar.
enum MenuIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { rect in
            let body = NSBezierPath(ovalIn: NSRect(x: 1, y: 2, width: 20, height: 16))
            NSGradient(colors: Palette.gradient.map { NSColor(hex: $0) })?.draw(in: body, angle: -60)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5, y: 6, width: 5.5, height: 5.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.5, y: 6, width: 5.5, height: 5.5)).fill()
            NSColor(hex: Palette.ink).setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.3, y: 6.8, width: 3, height: 3)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12.8, y: 6.8, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
