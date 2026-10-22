import AppKit
import Foundation

/// Actions that are hard to undo ask the user first, with a popup on the Mac: what the AI prompt says is
/// not enough on its own. Clicks are judged by what's under them, keys and typing by what they do.
enum ActionRisk {
    /// Labels that usually mean sending, spending, deleting, publishing, signing out or granting access.
    private static let riskyWords: [String] = [
        "send", "submit", "delete", "remove", "erase", "buy", "pay", "purchase", "order", "checkout", "confirm",
        "post", "publish", "share", "transfer", "withdraw", "sign out", "log out", "logout", "install", "uninstall",
        "empty trash", "reset", "format", "overwrite", "discard", "unsubscribe", "accept", "agree", "allow", "grant",
        "إرسال", "ارسال", "حذف", "إزالة", "شراء", "دفع", "تأكيد", "نشر", "مشاركة", "تحويل", "سحب",
        "تسجيل الخروج", "تثبيت", "إلغاء الاشتراك", "قبول", "سماح", "موافقة",
    ]

    /// Why a click on something with this label needs approval (nil if it looks harmless).
    static func clickRisk(_ label: String) -> String? {
        let text = label.lowercased()
        guard !text.isEmpty else { return nil }
        for word in riskyWords where matches(text, word) { return word }
        return nil
    }

    /// Whole-word match for Latin words (so "Postcard" doesn't match "post"); plain contains for Arabic.
    private static func matches(_ text: String, _ word: String) -> Bool {
        guard word.unicodeScalars.allSatisfy({ $0.isASCII }) else { return text.contains(word) }
        let pattern = "(^|[^a-z])" + NSRegularExpression.escapedPattern(for: word) + "($|[^a-z])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Keys that submit or close things.
    static func keysRisk(_ combo: String) -> Bool {
        let parts = combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let key = parts.last else { return false }
        let hasCommand = parts.contains { ["cmd", "command", "⌘", "meta", "super"].contains($0) }
        if ["return", "enter"].contains(key) { return true }
        if hasCommand, ["delete", "backspace", "forwarddelete", "del", "w"].contains(key) { return true }
        return false
    }

    /// Typing that also submits (Return at the end, or a line break in the text).
    static func typeRisk(text: String, pressReturn: Bool) -> Bool {
        pressReturn || text.contains("\n") || text.contains("\r")
    }

    /// Asks on the Mac. Denies by itself after 45 seconds, so an unattended Mac never hangs on a popup.
    @MainActor
    static func approve(_ title: String, detail: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = T("Bluey wants to do this")
        alert.informativeText = title + (detail.isEmpty ? "" : "\n\n" + detail)
        alert.addButton(withTitle: T("Allow"))
        alert.addButton(withTitle: T("Deny"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let timeout = DispatchWorkItem { NSApp.abortModal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
        let response = alert.runModal()
        timeout.cancel()
        return response == .alertFirstButtonReturn
    }
}
