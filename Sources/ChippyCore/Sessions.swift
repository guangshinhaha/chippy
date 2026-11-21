import Foundation

public enum SessionStatus: String { case idle, working, done }

public struct SessionRow: Identifiable, Equatable {
    public let id: String
    public var project: String
    public var cwd = ""
    public var branch: String?
    public var lastPrompt: String?
    public var lastReply: String?
    public var status: SessionStatus = .idle
    public var detail: String = "Session started"
    public var filesEdited: Set<String> = []
    public var added = 0
    public var removed = 0
    public var host: HostInfo?
    /// Live glance (#90): one allowlisted word from the tool name only (see `LiveGlance`). nil unless working.
    public var activity: String?
    /// When `activity` was last set by an event; the word goes stale after `LiveGlance.staleAfter`.
    public var activityAt: Date?
    public var updatedAt: Date

    /// The glance word if still fresh at `now`; nil when absent or older than `LiveGlance.staleAfter` (Esc/crash: no Stop came).
    public func liveActivity(now: Date) -> String? {
        guard let a = activity, let at = activityAt, now.timeIntervalSince(at) <= LiveGlance.staleAfter else { return nil }
        return a
    }

    /// One-line live status, e.g. "Claude Code · editing 3 files".
    public var headline: String {
        switch status {
        case .working where !filesEdited.isEmpty:
            return "Claude Code · editing \(filesEdited.count) file\(filesEdited.count == 1 ? "" : "s")"
        case .working: return "Claude Code · working"
        case .done: return "Claude Code · done"
        case .idle: return "Claude Code · idle"
        }
    }
}

/// Pure transition logic: one row per session id, never merged into a shared feed.
public struct SessionStore {
    public private(set) var rows: [SessionRow] = []
    public init() {}

    /// Fill in the host of a known session that has none (an approval from a session that predates Chippy, #164).
    /// Never replaces a host already known, and never creates a row.
    public mutating func learnHost(_ sessionId: String, _ host: HostInfo?) {
        guard let h = host, h.hasHost, let i = rows.firstIndex(where: { $0.id == sessionId }), !(rows[i].host?.hasHost ?? false) else { return }
        rows[i].host = h
    }

    public mutating func apply(_ p: HookPayload, now: Date = Date()) {
        if p.event == "SessionEnd" { rows.removeAll { $0.id == p.sessionId }; return }
        let i = rows.firstIndex { $0.id == p.sessionId } ?? {
            rows.append(SessionRow(id: p.sessionId, project: p.project, cwd: p.cwd, branch: p.branch, updatedAt: now))
            return rows.count - 1
        }()
        rows[i].updatedAt = now
        // Latest wins, but a tty-only report must not erase a known host app.
        if let h = p.host, h.hasHost || rows[i].host == nil { rows[i].host = h }
        // A late PostToolUse after Stop (parallel or subagent call) must not bring "Thinking" back on a finished session.
        // A new prompt is a real new turn, so it still does.
        let lateTool = p.event == "PostToolUse" && rows[i].status == .done
        if LiveGlance.touchesActivity(p.event) && !lateTool {
            rows[i].activity = LiveGlance.activity(after: p.event, tool: p.toolName, current: rows[i].activity)
            rows[i].activityAt = rows[i].activity == nil ? nil : now
        }
        switch p.event {
        case "SessionStart":
            rows[i].status = .idle; rows[i].detail = "Session started"
        case "UserPromptSubmit":
            rows[i].status = .working; rows[i].detail = "Thinking"
            if let c = SummaryCleaner.cleanPrompt(p.prompt) { rows[i].lastPrompt = String(c.prefix(140)) } // clean BEFORE truncating; a prompt that is all markup keeps the previous real one
        case "PreToolUse", "PostToolUse":
            rows[i].status = .working
            if let tool = p.toolName { rows[i].detail = describe(tool, p) }
            if p.event == "PostToolUse", let tool = p.toolName,
               let d = DiffCounts.forTool(tool, input: p.toolInput) {
                if let f = p.filePath { rows[i].filesEdited.insert(f) }
                rows[i].added += d.added; rows[i].removed += d.removed
                let name = p.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? tool
                rows[i].detail = "Edited \(name) +\(d.added) −\(d.removed)"
            }
        case "Stop":
            rows[i].status = .done; rows[i].detail = "Finished"
            rows[i].branch = p.branch ?? rows[i].branch
            rows[i].lastReply = p.lastMessage.map { String($0.prefix(6000)) }
        default: break
        }
    }

    private func describe(_ tool: String, _ p: HookPayload) -> String {
        let file = p.filePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit", "Write": return "Editing \(file ?? "file")"
        case "Read": return "Reading \(file ?? "file")"
        case "Bash": return "Running " + String((p.toolInput["command"] as? String ?? "command").prefix(40))
        default: return "Using \(tool)"
        }
    }

    /// Every session in glance order at `now`: needs-you first, then a FRESH live word, then working-but-stale, then the rest;
    /// newest first inside a group, ties broken by id so it is deterministic. Cheap (a handful of rows), so call it at read time.
    public func glanceOrder(now: Date = Date(), needsYou: Set<String> = []) -> [SessionRow] {
        func rank(_ r: SessionRow) -> Int {
            if needsYou.contains(r.id) { return 0 }
            if r.liveActivity(now: now) != nil { return 1 }
            return r.status == .working ? 2 : 3
        }
        return rows.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id < b.id
        }
    }

    /// Overall notch state derived from all sessions.
    public var derivedState: ChippyState {
        if rows.contains(where: { $0.status == .working }) { return .working }
        if rows.contains(where: { $0.status == .done }) { return .done }
        return .idle
    }
}
