import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon, which needs no Accessibility permission.
final class HotKeys {
    static let shared = HotKeys()

    /// Drops every registered shortcut (Shortcuts… menu re-registers with the user's combos).
    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        pressActions = [:]
        releaseActions = [:]
    }

    /// "⌃⌥P"-style label for a Carbon combo, using the active keyboard layout for the letter.
    static func describe(keyCode: Int, modifiers: Int) -> String {
        var label = ""
        if modifiers & controlKey != 0 { label += "⌃" }
        if modifiers & optionKey != 0 { label += "⌥" }
        if modifiers & shiftKey != 0 { label += "⇧" }
        if modifiers & cmdKey != 0 { label += "⌘" }
        return label + keyName(keyCode)
    }

    static func keyName(_ keyCode: Int) -> String {
        let specials = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                        kVK_Escape: "esc", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "="]
        if let name = specials[keyCode] { return name }
        if keyCode >= kVK_F1, keyCode <= kVK_F15 {
            let fnums = [kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8,
                         kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15]
            if let n = fnums[keyCode] { return "F\(n)" }
        }
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let layout = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self),
                                        UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            if status == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "Key \(keyCode)"
    }

    private var pressActions: [UInt32: () -> Void] = [:]
    private var releaseActions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    /// Registers `modifiers` + `key` (a kVK_ constant). Defaults to ⌃⌥.
    func register(keyCode: Int, modifiers: Int = controlKey | optionKey,
                  onRelease: (() -> Void)? = nil, onPress: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        pressActions[id] = onPress
        releaseActions[id] = onRelease
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x474F4F47), id: id)  // 'GOOG'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) } else { NSLog("Googly: hotkey \(keyCode) not registered (\(status))") }
    }

    fileprivate func fire(_ id: UInt32, pressed: Bool) {
        if pressed { pressActions[id]?() } else { releaseActions[id]?() }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { HotKeys.shared.fire(hotKeyID.id, pressed: pressed) }
            return noErr
        }, 2, &specs, nil, nil)
    }
}
