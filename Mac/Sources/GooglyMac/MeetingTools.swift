import AppKit
import Foundation

/// Search, action items and PDF export on top of the plain-file meeting notes.
extension MeetingNotes {
    // MARK: Sessions

    /// Every session folder that has notes, newest first.
    static func sessionFolders() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("notes.md").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// "Design review — 2026-10-21 14.30" (the notes title if there is one, else the folder name).
    static func title(of folder: URL) -> String {
        let first = (try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8))?
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        var name = first.hasPrefix("# ") ? String(first.dropFirst(2)) : ""
        if let colon = name.range(of: ": ") { name = String(name[..<colon.lowerBound]) }
        let stamp = String(folder.lastPathComponent.prefix(16))
        return name.isEmpty || name == "Bluey session" ? stamp : "\(name) — \(stamp)"
    }

    // MARK: Digest for the phone

    /// The session's existing folder (never creates one), matched the same careful way as `folder(session:started:)`.
    static func existingFolder(session: String) -> URL? {
        let tag = String(session.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8)).lowercased()
        guard !tag.isEmpty else { return nil }
        return sessionFolders().first { $0.lastPathComponent.hasSuffix(" " + tag) }
    }

    /// What the phone shows for a session: the summary text and its action items ("" and [] until the summary exists).
    static func digest(session: String) -> [String: Any] {
        guard let folder = existingFolder(session: session),
              let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8) else {
            return ["summary": "", "actions": [String]()]
        }
        return ["summary": summary, "actions": actionItems(in: summary)]
    }

    // MARK: Search

    struct Hit {
        var folder: URL
        var line: String
    }

    /// Case- and accent-insensitive search of every session's notes (Arabic included). At most 100 hits.
    static func search(_ query: String) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var hits: [Hit] = []
        for folder in sessionFolders() {
            guard let text = try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                hits.append(Hit(folder: folder, line: String(line).trimmingCharacters(in: CharacterSet(charactersIn: "> *"))))
                if hits.count >= 100 { return hits }
            }
        }
        return hits
    }

    // MARK: Action items

    /// "None", "None.", "N/A", "لا شيء" … — a summary saying there's nothing to do.
    static func isNone(_ item: String) -> Bool {
        let bare = item.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return bare.isEmpty || ["none", "n/a", "na", "nothing", "لا شيء", "لا يوجد", "لا توجد"].contains(bare)
    }

    /// The bullets under "**Action items**" in a summary ("None" and empty lists give []).
    static func actionItems(in summary: String) -> [String] {
        guard let marker = summary.range(of: "Action items", options: .caseInsensitive) else { return [] }
        var items: [String] = []
        for raw in summary[marker.upperBound...].split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") else { continue }
            let item = line.drop { "-*• ".contains($0) }.trimmingCharacters(in: .whitespaces)
            if !isNone(item) { items.append(item) }
        }
        return items
    }

    /// Writes action-items.md in the session folder and refreshes the all-sessions file. Called after a summary lands.
    static func writeActionItems(summary: String, folder: URL) {
        let items = actionItems(in: summary)
        let file = folder.appendingPathComponent("action-items.md")
        if items.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            let text = "# Action items — \(title(of: folder))\n\n" + items.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n"
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        rebuildAllActionItems()
    }

    /// "Action Items.md" in the notes folder: every session's open items, newest session first.
    /// Also fills in sessions that were summarized before this file existed.
    @discardableResult
    static func rebuildAllActionItems() -> URL {
        var out = ["# Action items across all meetings", ""]
        for folder in sessionFolders() {
            let own = folder.appendingPathComponent("action-items.md")
            var items: [String] = []
            if let saved = try? String(contentsOf: own, encoding: .utf8) {
                items = saved.split(separator: "\n").filter { $0.hasPrefix("- [") && !isNone(String($0.dropFirst(6))) }.map(String.init)
            } else if let summary = try? String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8) {
                items = actionItems(in: summary).map { "- [ ] \($0)" }
            }
            guard !items.isEmpty else { continue }
            out += ["## \(title(of: folder))", ""] + items + [""]
        }
        if out.count == 2 { out.append("No action items yet.") }
        let url = root.appendingPathComponent("Action Items.md")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: PDF

    /// Renders a session's notes.md into notes.pdf next to it (A4, multi-page, Arabic laid out right-to-left).
    @MainActor
    static func exportPDF(folder: URL) -> URL? {
        guard let markdown = try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) else { return nil }
        let pdf = folder.appendingPathComponent("notes.pdf")
        let page = NSSize(width: 595, height: 842)
        let margin: CGFloat = 48
        let width = page.width - margin * 2

        let body = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = .natural
        paragraph.alignment = .natural
        paragraph.paragraphSpacing = 6
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw
            var size: CGFloat = 11
            var weight = NSFont.Weight.regular
            if line.hasPrefix("# ") { line = String(line.dropFirst(2)); size = 20; weight = .bold }
            else if line.hasPrefix("## ") { line = String(line.dropFirst(3)); size = 15; weight = .semibold }
            var quoted = false
            if line.hasPrefix("> ") { line = String(line.dropFirst(2)); quoted = true }
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: quoted ? NSColor(white: 0.25, alpha: 1) : NSColor.black,
                .paragraphStyle: paragraph,
            ]
            // **bold** and other inline markdown, falling back to plain text if it doesn't parse.
            if let attributed = try? NSMutableAttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnly)) {
                attributed.addAttributes(base, range: NSRange(location: 0, length: attributed.length))
                attributed.enumerateAttribute(.inlinePresentationIntent, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                    if let intent = value as? Int, intent & 2 != 0 {  // strongEmphasis
                        attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: range)
                    }
                }
                body.append(attributed)
            } else {
                body.append(NSAttributedString(string: line, attributes: base))
            }
            body.append(NSAttributedString(string: "\n", attributes: base))
        }

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(body)
        view.isVerticallyResizable = true
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let height = ceil(view.layoutManager?.usedRect(for: view.textContainer!).height ?? 100) + 20
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let info = NSPrintInfo()
        info.paperSize = page
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run() && FileManager.default.fileExists(atPath: pdf.path) ? pdf : nil
    }
}
