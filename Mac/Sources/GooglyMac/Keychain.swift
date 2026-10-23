import Foundation

/// API keys live in a private file in ~/Library/Application Support/Googly (readable only by you),
/// never in the project folder or git. Unlike the Keychain, this never asks for your password.
enum Keychain {
    enum Key: String {
        case anthropic, elevenlabs, openai
        /// Base64 of the long-term TLS link key phones use to prove themselves (see GooglySecurity).
        case linkKey
    }

    private static var cache: [String: String]?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Googly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("keys.json")
    }

    /// Set when keys.json exists but can't be parsed: we then refuse to overwrite it, so a glitch can
    /// never silently drop the OpenAI key or unpair every phone.
    private static var unreadable = false

    private static func load() -> [String: String] {
        if let cache { return cache }
        var stored: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL) {
            if let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
                stored = parsed
            } else {
                unreadable = true
                NSLog("Googly: keys.json is unreadable; leaving it untouched")
            }
        }
        cache = stored
        return stored
    }

    static func get(_ key: Key) -> String? {
        guard let value = load()[key.rawValue], !value.isEmpty else { return nil }
        return value
    }

    static func set(_ key: Key, _ value: String?) {
        var all = load()
        all[key.rawValue] = value?.isEmpty == false ? value : nil
        cache = all
        guard !unreadable,
              let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) else { return }
        var url = fileURL
        let temp = url.deletingLastPathComponent().appendingPathComponent("keys.json.tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: temp)  // atomic swap of an existing file
        } else {
            try? FileManager.default.moveItem(at: temp, to: url)  // first run: nothing to replace yet
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // keys shouldn't ride along in Time Machine
        try? url.setResourceValues(values)
    }
}
