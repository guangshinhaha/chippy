import Foundation

/// Merges chippy-hook into a Claude Code settings.json. Pure; the CLI does backup, diff and confirmation.
public enum SettingsInstaller {
    /// Events relayed to the notch. PermissionRequest runs before the permission prompt and may answer it.
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd", "PermissionRequest"]
    public static let defaultApprovalTimeout = 20

    /// Claude's questions (AskUserQuestion) get longer than approvals: a person has to read the options.
    public static let defaultQuestionTimeout = 120

    public static func command(for binary: String, approvalTimeout: Int? = nil, questionTimeout: Int? = nil) -> String {
        "\"\(binary)\" relay" + (approvalTimeout.map { " --timeout \($0)" } ?? "")
            + (questionTimeout.map { " --question-timeout \($0)" } ?? "")
    }

    /// Claude Code kills the hook at this many seconds; ours must fire first, for whichever wait is longer.
    public static func hookTimeout(approvalTimeout: Int, questionTimeout: Int) -> Int { max(approvalTimeout, questionTimeout) + 10 }

    /// The integer after `flag` in a hook command line, if present.
    static func flagValue(_ flag: String, in command: String) -> Int? {
        let parts = command.split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(of: flag), i + 1 < parts.count else { return nil }
        return Int(parts[i + 1])
    }

    public static func merged(_ settings: [String: Any], binary: String, events: [String] = hookEvents,
                              approvalTimeout: Int = defaultApprovalTimeout,
                              questionTimeout: Int = defaultQuestionTimeout) -> [String: Any] {
        var out = settings
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var entries = hooks[ev] as? [[String: Any]] ?? []
            let permission = ev == "PermissionRequest"
            let cmd = command(for: binary, approvalTimeout: permission ? approvalTimeout : nil, questionTimeout: permission ? questionTimeout : nil)
            let timeout = hookTimeout(approvalTimeout: approvalTimeout, questionTimeout: questionTimeout)
            if hasChippyHook(entries) {
                // Upgrade in place: only chippy's own hook objects on PermissionRequest; everything else is left alone.
                if permission {
                    entries = entries.map { entry in
                        var entry = entry
                        guard let list = entry["hooks"] as? [Any] else { return entry }
                        entry["hooks"] = list.map { h -> Any in
                            guard var hook = h as? [String: Any], (hook["command"] as? String)?.contains("chippy-hook") == true else { return h }
                            // Keep the user's own --timeout / --question-timeout; defaults only fill missing flags.
                            let old = hook["command"] as? String ?? ""
                            let a = flagValue("--timeout", in: old) ?? approvalTimeout
                            let q = flagValue("--question-timeout", in: old) ?? questionTimeout
                            hook["command"] = command(for: binary, approvalTimeout: a, questionTimeout: q)
                            hook["timeout"] = hookTimeout(approvalTimeout: a, questionTimeout: q)
                            return hook
                        }
                        return entry
                    }
                    hooks[ev] = entries
                }
                continue
            }
            var hook: [String: Any] = ["type": "command", "command": cmd]
            if permission { hook["timeout"] = timeout } // let our own timeout fire first
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
