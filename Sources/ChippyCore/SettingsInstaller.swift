import Foundation

/// Merges chippy-hook into a Claude Code settings.json. Pure; the CLI does backup, diff and confirmation.
public enum SettingsInstaller {
    /// Events relayed to the notch. PermissionRequest runs before the permission prompt and may answer it.
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd", "PermissionRequest"]
    public static let defaultApprovalTimeout = 60

    /// The default before #99; an install with this value and no `--question-timeout` is an untouched old default.
    public static let legacyApprovalTimeout = 20

    /// Claude's questions (AskUserQuestion) get longer than approvals: a person has to read the options.
    public static let defaultQuestionTimeout = 120

    /// The longest wait the relay will take (`--timeout`, `--question-timeout`), also the cap for a reported `chippy_wait`.
    public static let maxApprovalTimeout = 120
    public static let maxQuestionTimeout = 300

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

    /// Why a chippy hook in `settings` is stale, empty when it is fine or absent.
    public enum Staleness: Equatable { case missingQuestionFlag, timeoutTooShort, missingPermissionRequest }

    public static func staleness(_ settings: [String: Any]) -> [Staleness] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        func chippyHooks(_ ev: String) -> [[String: Any]] {
            var out: [[String: Any]] = []
            for entry in hooks[ev] as? [Any] ?? [] {
                for h in (entry as? [String: Any])?["hooks"] as? [Any] ?? [] {
                    if let hook = h as? [String: Any], let cmd = hook["command"] as? String, cmd.contains("chippy-hook") { out.append(hook) }
                }
            }
            return out
        }
        let mine = chippyHooks("PermissionRequest")
        var out: [Staleness] = []
        if mine.isEmpty {
            // chippy-hook is installed for other events but its approval relay is gone.
            if hooks.keys.contains(where: { $0 != "PermissionRequest" && !chippyHooks($0).isEmpty }) { out.append(.missingPermissionRequest) }
            return out
        }
        for hook in mine {
            let cmd = hook["command"] as? String ?? ""
            let q = flagValue("--question-timeout", in: cmd)
            // No --timeout means the relay uses its current default, not the legacy one.
            let a = flagValue("--timeout", in: cmd) ?? defaultApprovalTimeout
            if q == nil, !out.contains(.missingQuestionFlag) { out.append(.missingQuestionFlag) }
            let need = hookTimeout(approvalTimeout: a, questionTimeout: q ?? 0)
            // NSNumber so 130.0 (a JSON double) counts as an int.
            let have = (hook["timeout"] as? NSNumber)?.intValue ?? 0
            if have < need, !out.contains(.timeoutTooShort) { out.append(.timeoutTooShort) }
        }
        return out
    }

    /// True when `path` will not exist later: a translocated, mounted-volume or temp-dir copy. build/ is fine.
    public static func isTransientPath(_ path: String, tempDir: String = NSTemporaryDirectory()) -> Bool {
        let p = (path as NSString).standardizingPath
        let t = (tempDir as NSString).standardizingPath
        if p.contains("/AppTranslocation/") || p.hasPrefix("/Volumes/") { return true }
        for root in [t, "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"] where !root.isEmpty && root != "/" {
            if p == root || p.hasPrefix(root + "/") { return true }
        }
        return false
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
                            let qOld = flagValue("--question-timeout", in: old)
                            var a = flagValue("--timeout", in: old) ?? approvalTimeout
                            // Old default (20, written before the question flag existed) moves to the new default.
                            if qOld == nil, a == legacyApprovalTimeout { a = approvalTimeout }
                            let q = qOld ?? questionTimeout
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
