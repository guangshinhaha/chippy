import Combine
import Foundation

/// The four v1 states. FYI and Error are deferred past v1 (PRD §5).
public enum ChippyState: String, CaseIterable, Codable {
    case idle, working, needsYou, done

    public var title: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        }
    }
}

public enum Density: String, CaseIterable {
    case collapsed, compact, expanded

    public var title: String { rawValue.capitalized }
}

public final class NotchModel: ObservableObject {
    @Published public var state: ChippyState
    @Published public var density: Density
    @Published public private(set) var sessions: [SessionRow] = []
    /// When true (debug menu), live sessions don't drive state/density.
    @Published public var debugLock = false { didSet { refresh() } }
    @Published public private(set) var pending: [PendingRequest] = []
    /// The user clicked the notch open to look at sessions (menu peek); closed again by another click.
    @Published public private(set) var pinnedOpen = false
    /// Finished threads waiting to be acknowledged. Sticky: they stay until dismissed, the thread moves on, or they age out.
    @Published public private(set) var doneItems: [DoneItem] = []
    /// The done chip was clicked: show what the finished threads did.
    @Published public private(set) var doneOpen = false
    /// The notch only appears when something needs the user: an approval, a finished thread, or a menu-bar peek.
    @Published public private(set) var visible = false
    public static let doneSeconds: TimeInterval = 600
    private var store = SessionStore()
    private var connections: [String: Connection] = [:]
    private let always: AlwaysStore
    private let log: EventLog

    public init(state: ChippyState = .idle, density: Density = .collapsed,
                always: AlwaysStore = AlwaysStore(), log: EventLog = EventLog()) {
        self.state = state
        self.density = density
        self.always = always
        self.log = log
    }

    private func refresh() {
        guard !debugLock else { visible = true; return }
        if sessions.isEmpty { pinnedOpen = false }
        if doneItems.isEmpty { doneOpen = false }
        let live = store.derivedState
        state = !pending.isEmpty ? .needsYou : (live == .working ? .working : (doneItems.isEmpty ? live : .done))
        if !pending.isEmpty || pinnedOpen || doneOpen { density = .expanded; visible = true }
        else if !doneItems.isEmpty { density = .compact; visible = true }
        else { density = .collapsed; visible = false }
    }

    /// Click on the notch. A waiting approval ignores it. A done chip opens its detail (click again to go back);
    /// otherwise it opens or closes the session peek.
    public func toggleOpen() {
        guard pending.isEmpty else { return }
        if !doneItems.isEmpty && !pinnedOpen { doneOpen.toggle() } else { pinnedOpen.toggle() }
        refresh()
    }

    /// Acknowledge one finished thread, or all of them.
    public func dismissDone(_ sessionId: String? = nil) {
        if let sessionId { doneItems.removeAll { $0.sessionId == sessionId } } else { doneItems.removeAll() }
        refresh()
    }

    /// A PermissionRequest hook is waiting on `conn`. Main thread only.
    /// AskUserQuestion is never intercepted: no reply, so it goes to the terminal as normal.
    public func receiveApproval(_ payload: HookPayload, _ conn: Connection) {
        guard payload.toolName != "AskUserQuestion" else { conn.respond(nil); return }
        var req = PendingRequest(payload: payload)
        req.lastPrompt = sessions.first { $0.id == payload.sessionId }?.lastPrompt
        if always.contains(req) {
            conn.respond(Decision.allow.reply)
            log.append(req, channel: .notch, decision: "auto_always", now: req.createdAt)
            return
        }
        pending.append(req)
        connections[req.id] = conn
        refresh()
    }

    /// Resolve exactly the request with this id. Stale or unknown ids are ignored.
    public func resolve(_ id: String, _ decision: Decision, now: Date = Date()) {
        guard let i = pending.firstIndex(where: { $0.id == id }), let conn = connections.removeValue(forKey: id) else { return }
        let req = pending.remove(at: i)
        if conn.peerGone { // the hook already gave up (timeout) or the terminal answered: this click is stale
            conn.respond(nil)
            log.append(req, channel: .terminal, decision: "none", now: now)
            refresh()
            return
        }
        if decision == .always { always.insert(req) }
        conn.respond(decision.reply)
        log.append(req, channel: .notch, decision: "\(decision)", now: now)
        refresh()
    }

    /// Drop requests whose hook went away (timeout fallback, or answered in the terminal).
    public func sweep(now: Date = Date()) {
        let gone = pending.filter { connections[$0.id]?.peerGone ?? true }
        let before = doneItems.count
        doneItems.removeAll { now.timeIntervalSince($0.at) > Self.doneSeconds }
        if doneItems.count != before { refresh() }
        guard !gone.isEmpty else { return }
        for r in gone {
            connections.removeValue(forKey: r.id)?.respond(nil)
            log.append(r, channel: .terminal, decision: "none", now: now)
        }
        pending.removeAll { r in gone.contains { $0.id == r.id } }
        refresh()
    }

    /// Apply a live hook event. Main thread only.
    public func apply(_ payload: HookPayload, now: Date = Date()) {
        store.apply(payload, now: now)
        sessions = store.rows
        switch payload.event {
        case "Stop" where !payload.isAgentWorktree:
            if let r = sessions.first(where: { $0.id == payload.sessionId }) {
                doneItems.removeAll { $0.sessionId == r.id }
                doneItems.append(DoneItem(sessionId: r.id, project: r.project, branch: r.branch,
                                          files: r.filesEdited.count, added: r.added, removed: r.removed, at: now))
            }
        case "UserPromptSubmit", "SessionEnd", "PreToolUse", "PostToolUse":
            // Only the thread itself moving on (new prompt, tool use after a Stop, or ending) clears its chip; another thread's activity must not.
            doneItems.removeAll { $0.sessionId == payload.sessionId }
        default: break
        }
        refresh()
    }
}

public struct DoneItem: Identifiable, Equatable {
    public var id: String { sessionId }
    public let sessionId: String
    public let project: String
    public let branch: String?
    public let files: Int
    public let added: Int
    public let removed: Int
    public let at: Date

    /// "repo · branch", or just the repo.
    public var identity: String { branch.map { "\(project) · \($0)" } ?? project }
}
