import Foundation

/// Merges chippy-hook into a Claude Code settings.json. Pure; the CLI does backup, diff and confirmation.
public enum SettingsInstaller {
    /// Events relayed to the notch. PermissionRequest runs before the permission prompt and may answer it.
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd", "PermissionRequest"]
    public static let defaultApprovalTimeout = 20

    public static func command(for binary: String, approvalTimeout: Int? = nil) -> String {
        "\"\(binary)\" relay" + (approvalTimeout.map { " --timeout \($0)" } ?? "")
    }

    public static func merged(_ settings: [String: Any], binary: String, events: [String] = hookEvents,
                              approvalTimeout: Int = defaultApprovalTimeout) -> [String: Any] {
        var out = settings
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var entries = hooks[ev] as? [[String: Any]] ?? []
            let already = entries.contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains("chippy-hook") == true }
            }
            if already { continue }
            var hook: [String: Any] = ["type": "command", "command": command(for: binary)]
            if ev == "PermissionRequest" {
                hook["command"] = command(for: binary, approvalTimeout: approvalTimeout)
                hook["timeout"] = approvalTimeout + 10 // let our own timeout fire first
            }
            entries.append(["matcher": "*", "hooks": [hook]])
            hooks[ev] = entries
        }
        out["hooks"] = hooks
        return out
    }

    public static func render(_ obj: [String: Any]) throws -> Data {
        var d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        d.append(10)
        return d
    }
}
