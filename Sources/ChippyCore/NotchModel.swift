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
    /// The user clicked the notch open to look at sessions; closed again by another click.
    @Published public private(set) var pinnedOpen = false
    /// The notch only appears when something needs the user: an approval, a just-finished toast, or a menu-bar peek.
    @Published public private(set) var visible = false
    private var toastUntil: Date?
    public static let toastSeconds: TimeInterval = 6
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

    private func refresh(now: Date = Date()) {
        if let t = toastUntil, now >= t { toastUntil = nil }
        guard !debugLock else { visible = true; return }
        if sessions.isEmpty { pinnedOpen = false } // nothing to look at: don't stay open on an empty list
        state = pending.isEmpty ? store.derivedState : .needsYou
        if !pending.isEmpty || pinnedOpen { density = .expanded; visible = true }
        else if toastUntil != nil { density = .compact; visible = true }
        else { density = .collapsed; visible = false }
    }

    /// Click on the notch: open the session list, or close it. A waiting approval keeps it open regardless.
    public func toggleOpen(now: Date = Date()) {
        guard pending.isEmpty else { return } // an approval holds it open; don't flip the pin unseen
        pinnedOpen.toggle()
        refresh(now: now)
    }

    /// A PermissionRequest hook is waiting on `conn`. Main thread only.
    /// AskUserQuestion is never intercepted: no reply, so it goes to the terminal as normal.
    public func receiveApproval(_ payload: HookPayload, _ conn: Connection) {
        guard payload.toolName != "AskUserQuestion" else { conn.respond(nil); return }
        let req = PendingRequest(payload: payload)
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
        guard !gone.isEmpty else { if toastUntil != nil { refresh(now: now) }; return }
        for r in gone {
            connections.removeValue(forKey: r.id)?.respond(nil)
            log.append(r, channel: .terminal, decision: "none", now: now)
        }
        pending.removeAll { r in gone.contains { $0.id == r.id } }
        refresh(now: now)
    }

    /// Apply a live hook event. Main thread only.
    public func apply(_ payload: HookPayload, now: Date = Date()) {
        store.apply(payload)
        sessions = store.rows
        if payload.event == "Stop" { toastUntil = now.addingTimeInterval(Self.toastSeconds) } // finished: say so briefly
        if payload.event == "SessionEnd" || payload.event == "UserPromptSubmit" { toastUntil = nil }
        refresh(now: now)
    }
}
