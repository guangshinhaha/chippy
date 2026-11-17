import Foundation

/// Pure logic for the first-run tour (#27): captions, step order, the hooks check and the Connect script.
public enum Tour {
    public enum Step: String, CaseIterable { case approval, question, done }
    public static let steps = Step.allCases
    public static let stepTimeout: TimeInterval = 60
    public static let defaultsKey = "didShowTour"
    public static let notConnectedCaption = "Chippy isn't connected to Claude Code yet."

    public static func isDemo(_ sessionId: String) -> Bool { sessionId.hasPrefix("demo-") }

    /// Caption under a card; nil for real sessions. On the done card, `connected == false` swaps in the connect prompt.
    public static func caption(sessionId: String, step: Step, connected: Bool = true) -> String? {
        guard isDemo(sessionId) else { return nil }
        switch step {
        case .approval: return "Claude wants to run something. Allow or Deny here, or in the terminal."
        case .question: return "Claude asks you something. Pick an answer here."
        case .done:
            return connected ? "A thread finished. Click to read the reply; it stays up until you dismiss it."
                             : notConnectedCaption
        }
    }

    /// True when settings.json text has a chippy-hook PermissionRequest entry. Unreadable or invalid means not connected.
    public static func hooksConnected(settingsText: String?) -> Bool {
        guard let t = settingsText, let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any] else { return false }
        return SettingsInstaller.hasChippyHook(hooks["PermissionRequest"])
    }

    /// A .command script that runs the existing install flow (which shows a diff and asks) in Terminal.
    public static func connectScript(binary: String) -> String {
        let q = "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "#!/bin/zsh\n\(q) install\necho\nread -k 1 '?Press any key to close.'\n"
    }
}
