import Foundation

/// The subset of a Claude Code hook payload Chippy cares about.
public struct HookPayload {
    public let sessionId: String
    public let cwd: String
    public let event: String
    public let toolName: String?
    public let toolInput: [String: Any]
    /// The user's prompt (UserPromptSubmit only). Kept in memory for context on the card, never logged or sent anywhere.
    public let prompt: String?
    /// Claude's final message (Stop only). In memory for the done card; never logged or sent anywhere.
    public let lastMessage: String?
    /// Host app + tty added by the relay (SessionStart/UserPromptSubmit/Stop). In memory only.
    public let host: HostInfo?
    /// What Claude said just before an AskUserQuestion, added by the relay. In memory only: never logged or sent anywhere.
    public let leadIn: String?
    /// Claude Code's transcript file (all events carry it). Read only by the relay; not stored.
    public let transcriptPath: String?
    /// How long the relay waits for an answer (PermissionRequest only), as the hook was installed. nil from an older relay.
    public let waitSeconds: TimeInterval?
    private let branchOverride: String?

    public init?(json: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sid = o["session_id"] as? String, let ev = o["hook_event_name"] as? String
        else { return nil }
        sessionId = sid
        event = ev
        cwd = o["cwd"] as? String ?? ""
        toolName = o["tool_name"] as? String
        toolInput = o["tool_input"] as? [String: Any] ?? [:]
        prompt = o["prompt"] as? String
        lastMessage = o["last_assistant_message"] as? String
        let hp = (o["chippy_host_pid"] as? NSNumber)?.int32Value
        let hb = o["chippy_host_bundle"] as? String, tty = o["chippy_tty"] as? String
        host = (hp != nil || hb != nil || tty != nil) ? HostInfo(pid: hp, bundle: hb, tty: tty, cwd: cwd.isEmpty ? nil : cwd) : nil
        leadIn = (o["chippy_lead_in"] as? String).map { TranscriptTail.truncate($0, to: TranscriptTail.maxChars) }
        transcriptPath = o["transcript_path"] as? String
        branchOverride = o["chippy_branch"] as? String // only the demo command sets this
        waitSeconds = (o["chippy_wait"] as? NSNumber).map(\.doubleValue).flatMap { $0 >= 1 && $0 <= 600 ? $0 : nil }
    }

    /// Repo name for the session. A Claude worktree (`<repo>/.claude/worktrees/agent-xyz`) is labelled by its repo,
    /// not by the throwaway folder name.
    public var project: String {
        if cwd.isEmpty { return "unknown" }
        if let r = cwd.range(of: "/.claude/worktrees/") {
            let prefix = String(cwd[..<r.lowerBound])
            if !prefix.isEmpty { let repo = URL(fileURLWithPath: prefix).lastPathComponent; if !repo.isEmpty { return repo } }
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// An automated agent running in its own worktree: nobody is waiting on its "finished".
    public var isAgentWorktree: Bool { cwd.contains("/.claude/worktrees/agent-") }

    public var branch: String? { branchOverride ?? GitInfo.branch(cwd: cwd) }

    public var filePath: String? { toolInput["file_path"] as? String }
}

public enum DiffCounts {
    static func lines(_ s: String) -> Int { s.isEmpty ? 0 : s.split(separator: "\n", omittingEmptySubsequences: false).count }

    /// (added, removed) line counts for an edit tool call; nil if the tool isn't an edit.
    public static func forTool(_ name: String, input: [String: Any]) -> (added: Int, removed: Int)? {
        switch name {
        case "Edit":
            return (lines(input["new_string"] as? String ?? ""), lines(input["old_string"] as? String ?? ""))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return edits.reduce((0, 0)) {
                ($0.0 + lines($1["new_string"] as? String ?? ""), $0.1 + lines($1["old_string"] as? String ?? ""))
            }
        case "Write":
            return (lines(input["content"] as? String ?? ""), 0)
        default:
            return nil
        }
    }
}
