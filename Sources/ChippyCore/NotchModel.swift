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
    @Published public var debugLock = false
    @Published public private(set) var pending: [PendingRequest] = []
    private var store = SessionStore()
    private var connections: [String: Connection] = [:]
    private let always: AlwaysStore

    public init(state: ChippyState = .idle, density: Density = .collapsed, always: AlwaysStore = AlwaysStore()) {
        self.state = state
        self.density = density
        self.always = always
    }

    private func refresh() {
        guard !debugLock else { return }
        if !pending.isEmpty { state = .needsYou; density = .expanded }
        else {
            state = store.derivedState
            density = sessions.isEmpty ? .collapsed : .compact
        }
    }

    /// A PermissionRequest hook is waiting on `conn`. Main thread only.
    /// AskUserQuestion is never intercepted: no reply, so it goes to the terminal as normal.
    public func receiveApproval(_ payload: HookPayload, _ conn: Connection) {
        guard payload.toolName != "AskUserQuestion" else { conn.respond(nil); return }
        let req = PendingRequest(payload: payload)
        if always.contains(req) { conn.respond(Decision.allow.reply); return }
        pending.append(req)
        connections[req.id] = conn
        refresh()
    }

    /// Resolve exactly the request with this id. Stale or unknown ids are ignored.
    public func resolve(_ id: String, _ decision: Decision) {
        guard let i = pending.firstIndex(where: { $0.id == id }), let conn = connections.removeValue(forKey: id) else { return }
        let req = pending.remove(at: i)
        if conn.peerGone { // the hook already gave up (timeout) or the terminal answered: this click is stale
            conn.respond(nil)
            refresh()
            return
        }
        if decision == .always { always.insert(req) }
        conn.respond(decision.reply)
        refresh()
    }

    /// Drop requests whose hook went away (timeout fallback, or answered in the terminal).
    public func sweep() {
        let gone = pending.filter { connections[$0.id]?.peerGone ?? true }
        guard !gone.isEmpty else { return }
        for r in gone { connections.removeValue(forKey: r.id)?.respond(nil) }
        pending.removeAll { r in gone.contains { $0.id == r.id } }
        refresh()
    }

    /// Apply a live hook event. Main thread only.
    public func apply(_ payload: HookPayload) {
        store.apply(payload)
        sessions = store.rows
        refresh()
    }
}
