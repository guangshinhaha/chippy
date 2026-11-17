import Foundation

/// The subset of a Claude Code hook payload Chippy cares about.
public struct HookPayload {
    public let sessionId: String
    public let cwd: String
    public let event: String
    public let toolName: String?
    public let toolInput: [String: Any]

    public init?(json: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sid = o["session_id"] as? String, let ev = o["hook_event_name"] as? String
        else { return nil }
        sessionId = sid
        event = ev
        cwd = o["cwd"] as? String ?? ""
        toolName = o["tool_name"] as? String
        toolInput = o["tool_input"] as? [String: Any] ?? [:]
    }

    /// Repo name for the session. A Claude worktree (`<repo>/.claude/worktrees/agent-xyz`) is labelled by its repo,
    /// not by the throwaway folder name.
    public var project: String {
        if cwd.isEmpty { return "unknown" }
        if let r = cwd.range(of: "/.claude/worktrees/") {
            let repo = URL(fileURLWithPath: String(cwd[..<r.lowerBound])).lastPathComponent
            if !repo.isEmpty { return repo }
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// An automated agent running in its own worktree: nobody is waiting on its "finished".
    public var isAgentWorktree: Bool { cwd.contains("/.claude/worktrees/agent-") }

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
