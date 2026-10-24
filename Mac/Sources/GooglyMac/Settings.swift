import Foundation

/// Looks a string up in the app's Localizable.strings (Arabic when the Mac is set to Arabic; otherwise the English text).
func T(_ key: String) -> String { NSLocalizedString(key, comment: "") }
import GooglyShared

/// User choices from the menu bar, kept between launches.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var onChange: (() -> Void)?

    /// A user-rebound global shortcut ("keyCode,carbonModifiers") or nil for the default.
    static func hotkeyOverride(for id: String) -> (keyCode: Int, modifiers: Int)? {
        guard let raw = UserDefaults.standard.string(forKey: "hotkey." + id) else { return nil }
        let parts = raw.split(separator: ",").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static func setHotkeyOverride(for id: String, _ combo: (keyCode: Int, modifiers: Int)?) {
        if let combo {
            UserDefaults.standard.set("\(combo.keyCode),\(combo.modifiers)", forKey: "hotkey." + id)
        } else {
            UserDefaults.standard.removeObject(forKey: "hotkey." + id)
        }
    }

    /// Cursor size in points (the design's default is 72).
    var cursorSize: Double {
        get { defaults.object(forKey: "cursorSize") as? Double ?? 72 }
        set { defaults.set(newValue, forKey: "cursorSize"); onChange?() }
    }

    var glow: Bool {
        get { defaults.object(forKey: "glow") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "glow"); onChange?() }
    }

    var showCursor: Bool {
        get { defaults.object(forKey: "showCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showCursor"); onChange?() }
    }

    /// Where the phone sits under the screen, 0 = left edge, 1 = right edge.
    var phonePosition: Double {
        get { defaults.object(forKey: "phonePosition") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "phonePosition"); onChange?() }
    }

    /// When idle, hide the big cursor and let the phone's eyes follow your own mouse.
    var followMouse: Bool {
        get { defaults.object(forKey: "followMouse") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "followMouse"); onChange?() }
    }

    var captions: Bool {
        get { defaults.object(forKey: "captions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captions"); onChange?() }
    }

    /// Lets him click, type, press keys and open things when you ask.
    var computerControl: Bool {
        // Off for new installs; anyone who has already let him act (there is an action log) keeps it on.
        get {
            defaults.object(forKey: "computerControl") as? Bool
                ?? FileManager.default.fileExists(atPath: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Googly/actions.log").path)
        }
        set { defaults.set(newValue, forKey: "computerControl"); onChange?() }
    }

    /// Pops up on the Mac before anything hard to undo (sending, deleting, buying, Return, closing…).
    var askBeforeRisky: Bool {
        get { defaults.object(forKey: "askBeforeRisky") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "askBeforeRisky"); onChange?() }
    }

    /// How the cursor's path shows while it flies.
    var trail: PointerTrail {
        get { PointerTrail(rawValue: defaults.string(forKey: "trail") ?? "") ?? .comet }
        set { defaults.set(newValue.rawValue, forKey: "trail"); onChange?() }
    }

    /// The mood picked by hand in the menu.
    var mood: Mood {
        get { Mood(rawValue: defaults.string(forKey: "mood") ?? "") ?? .listening }
        set { defaults.set(newValue.rawValue, forKey: "mood"); onChange?() }
    }
}
