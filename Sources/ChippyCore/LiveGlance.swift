import Foundation
import CoreGraphics

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

    /// A word older than this with no new event is treated as stale (Esc or a crash sends no Stop).
    public static let staleAfter: TimeInterval = 90

    /// The activity after a hook event. Only Stop and SessionStart clear it; PreToolUse names the tool; PostToolUse and a
    /// new prompt mean the model is between tools: Thinking. Notification, SubagentStop, PreCompact and unknown events
    /// say nothing about what the main thread is doing, so the current word stays.
    public static func activity(after event: String, tool: String?, current: String? = nil) -> String? {
        switch event {
        case "Stop", "SessionStart": return nil
        case "PreToolUse": return word(forTool: tool)
        case "PostToolUse", "UserPromptSubmit": return thinking
        default: return current
        }
    }

    /// Whether this event sets or clears the word (so `activityAt` moves). Other events keep the word and its age.
    static func touchesActivity(_ event: String) -> Bool {
        ["Stop", "SessionStart", "PreToolUse", "PostToolUse", "UserPromptSubmit"].contains(event)
    }

    /// The text for a session's glance line and whether it is live. Evaluated at read time, so a stale word falls back to the state.
    /// Order: blocked (approval/question: "Needs you"; terminal ask: "Waiting for you"), fresh word, Finished, Working (stale word, still running), else Idle.
    /// The session model has no error state, so none is shown.
    public static func line(for row: SessionRow, now: Date, needsYou: Bool = false, waitingTerminal: Bool = false) -> (text: String, live: Bool) {
        if needsYou { return ("Needs you", false) }
        if waitingTerminal { return ("Waiting for you", false) }
        if let w = row.liveActivity(now: now) { return (w, true) }
        switch row.status {
        case .done: return ("Finished", false)
        case .working: return (fallback, false) // a long tool run (>90s) is still running, not idle
        case .idle: return ("Idle", false)
        }
    }
}

/// Height budget for the glance rows in the open panel. The app measures the card, but a static render (gallery) and the
/// panel cap both need the row count turned into points, so the row height lives here once.
public enum GlanceMetrics {
    public static let rowHeight: CGFloat = 18
    public static let rowCap = 4
    /// The "N more sessions" footnote (caption2).
    public static let moreHeight: CGFloat = 14
    public static func height(rows: Int) -> CGFloat {
        CGFloat(min(rows, rowCap)) * rowHeight + (rows > rowCap ? moreHeight : 0)
    }
}
