import AppKit
import Foundation

/// A plain-text record of everything he did on the computer, kept in Application Support.
/// Menu → "Recent Actions…" shows it; the file can be read or deleted like any other.
enum ActionLog {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("actions.log")
    }

    /// One line per action (or refusal). `detail` is whatever identifies it: the thing clicked,
    /// the keys pressed, the app opened. `outcome` is how it ended, one short line.
    static func record(_ action: String, _ detail: String, outcome: String) {
        // Tool arguments can contain newlines/tabs, which would forge extra log lines; and the screen
        // text that comes back with an action doesn't belong on disk. Keep one short, clean line.
        func clean(_ s: String, _ limit: Int) -> String {
            let flat = (s.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                .replacingOccurrences(of: "\t", with: " ")
            return String(flat.prefix(limit))
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let clipped = "\(stamp)\t\(clean(action, 20))\t\(clean(detail, 80))\t\(clean(outcome, 100))\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(Data(clipped.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data(clipped.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
        trim()
    }

    /// Keeps the log from growing past ~2,000 lines: drops the oldest half.
    private static func trim() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" }
        guard lines.count > 2000 else { return }
        let kept = lines.suffix(1000).joined(separator: "\n")
        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func recent(_ count: Int = 100) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty else {
            return "Nothing yet — he hasn't used the computer."
        }
        let lines = text.split { $0 == "\n" }.suffix(count)
        let clock = ISO8601DateFormatter(), short = DateFormatter()
        short.dateFormat = "h:mm:ss a"
        return lines.reversed().map { line in
            let parts = line.split(separator: "\t", maxSplits: 3)
            guard parts.count == 4, let date = clock.date(from: String(parts[0])) else { return String(line) }
            return "\(short.string(from: date))  \(parts[1]): \(parts[2]) — \(parts[3])"
        }.joined(separator: "\n")
    }

    static func clear() { try? FileManager.default.removeItem(at: fileURL) }
}
