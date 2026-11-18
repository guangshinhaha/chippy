import Foundation

/// Live glance (#90): one word for what a running session is doing, taken from the TOOL NAME ONLY.
/// Never a path, command, prompt or any tool input. Unknown and MCP tools say "Working", never their own name
/// (a custom tool name can carry a server or customer name). Pure; the word lives in memory on `SessionRow`, never logged.
public enum LiveGlance {
    public static let fallback = "Working"
    public static let thinking = "Thinking"

    private static let map: [String: String] = [
        "Read": "Reading", "NotebookRead": "Reading",
        "Edit": "Editing", "MultiEdit": "Editing", "Write": "Editing", "NotebookEdit": "Editing",
        "Bash": "Running", "BashOutput": "Running", "KillShell": "Running",
        "Grep": "Searching", "Glob": "Searching", "WebSearch": "Searching", "WebFetch": "Searching", "LS": "Searching",
        "Task": "Delegating", "Agent": "Delegating",
        "TodoWrite": "Planning", "ExitPlanMode": "Planning",
    ]

    /// The allowlisted word for a tool name; anything else (including nil) is "Working".
    public static func word(forTool name: String?) -> String {
        guard let name else { return fallback }
        return map[name] ?? fallback
    }

    /// The activity after a hook event, or nil when the session is not actively working (Stop, SessionStart, anything else).
    /// PreToolUse names the tool; PostToolUse and a new prompt mean the model is between tools: Thinking.
    public static func activity(after event: String, tool: String?) -> String? {
        switch event {
        case "PreToolUse": return word(forTool: tool)
        case "PostToolUse", "UserPromptSubmit": return thinking
        default: return nil
        }
    }
}
