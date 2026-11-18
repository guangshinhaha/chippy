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
    /// The done detail is open: the panel grows so the whole reply can be read.
    @Published public private(set) var tall = false
    /// The notch only appears when something needs the user: an approval, a finished thread, or a menu-bar peek.
    @Published public private(set) var visible = false
    /// Off by default (PDPA): the glance shows only `repo · finished`; the reply stays behind the click.
    @Published public var showReplyInGlance = UserDefaults.standard.bool(forKey: "showReplyInGlance") {
        didSet { UserDefaults.standard.set(showReplyInGlance, forKey: "showReplyInGlance") }
    }
    public static let doneSeconds: TimeInterval = 600
    /// A finished chip is shown compact while peeking, then the island settles to collapsed (chip stays in `doneItems`).
    @Published public private(set) var peeking = false
    private var peek = PeekGate()
    /// Last pointer state from the panel, kept even while expanded so a new peek can start from it.
    private var hovering = false
    private let clock: () -> TimeInterval
    private var store = SessionStore()
    private var connections: [String: Connection] = [:]
    private var questionInputs: [String: [String: Any]] = [:]
    /// Sound hook (#67): fired for a new approval/question and a finished chip. The app decides whether to play.
    public var onSound: ((SoundKind, _ sessionId: String, _ host: HostInfo?) -> Void)?
    /// Fired when a session ends, so callers can drop per-session state.
    public var onSessionEnd: ((String) -> Void)?
    private let always: AlwaysStore
    private let log: EventLog

    public init(state: ChippyState = .idle, density: Density = .collapsed,
                always: AlwaysStore = AlwaysStore(), log: EventLog = EventLog(),
                clock: @escaping () -> TimeInterval = PeekGate.monotonicNow) {
        self.clock = clock
        self.state = state
        self.density = density
        self.always = always
        self.log = log
    }

    private func refresh() {
        guard !debugLock else { visible = true; return }
        if sessions.isEmpty { pinnedOpen = false }
        if doneItems.isEmpty { doneOpen = false; peek.cancel() }
        if !pending.isEmpty || pinnedOpen || doneOpen { peek.cancel() } // the user (or an approval) took over: no peek to resume on close
        let p = peek.isPeeking(now: clock())
        if p != peeking { peeking = p }
        let live = store.derivedState
        state = !pending.isEmpty ? .needsYou : (live == .working ? .working : (doneItems.isEmpty ? live : .done))
        tall = pending.isEmpty && !pinnedOpen && doneOpen
        if !pending.isEmpty || pinnedOpen || doneOpen { density = .expanded; visible = true }
        else if !doneItems.isEmpty { density = peeking ? .compact : .collapsed; visible = true }
        else { density = .collapsed; visible = false }
    }

    /// Count shown on the collapsed notch while finished items wait (nil at 0, "9+" over 9).
    public var badge: String? { PeekGate.badge(count: doneItems.count) }

    /// The pointer entered or left the island: a running peek holds while it is over and resumes when it leaves.
    /// Ignored while expanded, and it never re-opens an expired peek.
    public func setHover(_ inside: Bool) {
        hovering = inside
        guard density != .expanded else { return }
        peek.setHover(inside, now: clock())
    }

    /// Click on the notch. A waiting approval ignores it. A done chip opens its detail (click again to go back);
    /// otherwise it opens or closes the session peek.
    public func toggleOpen() {
        guard pending.isEmpty else { return }
        if !doneItems.isEmpty && !pinnedOpen { doneOpen.toggle() } else { pinnedOpen.toggle() }
        refresh()
    }

    /// Click outside the notch: fold an open detail or peek back to its glance. A waiting approval stays.
    public func closeDetail() {
        guard pending.isEmpty, doneOpen || pinnedOpen else { return }
        doneOpen = false; pinnedOpen = false
        refresh()
    }

    /// Acknowledge one finished thread, or all of them.
    public func dismissDone(_ sessionId: String? = nil) {
        if let sessionId { doneItems.removeAll { $0.sessionId == sessionId } } else { doneItems.removeAll() }
        refresh()
    }

    /// A PermissionRequest hook is waiting on `conn`. Main thread only.
    /// AskUserQuestion is answerable when every question parses (single or multi-select); otherwise no reply, so the terminal handles it.
    public func receiveApproval(_ payload: HookPayload, _ conn: Connection) {
        var req = PendingRequest(payload: payload)
        if payload.toolName == "AskUserQuestion" {
            guard req.questions != nil else { conn.respond(nil); return }
            questionInputs[req.id] = payload.toolInput
        }
        req.lastPrompt = sessions.first { $0.id == payload.sessionId }?.lastPrompt
        if req.questions == nil, always.contains(req) {
            conn.respond(Decision.allow.reply)
            record(req, channel: .notch, decision: "auto_always", now: req.createdAt)
            return
        }
        pending.append(req)
        connections[req.id] = conn
        refresh()
        if !Tour.isDemo(req.sessionId) {
            onSound?(.needsYou, req.sessionId, sessions.first { $0.id == req.sessionId }?.host ?? payload.host)
        }
    }

    /// Log a handled approval, except demo cards (`chippy-hook demo`, session ids `demo-*`), which would skew the measure.
    private func record(_ r: PendingRequest, channel: Channel, decision: String, now: Date) {
        guard !r.sessionId.hasPrefix("demo-") else { return }
        log.append(r, channel: channel, decision: decision, now: now)
    }

    /// Resolve exactly the request with this id. Stale or unknown ids are ignored.
    public func resolve(_ id: String, _ decision: Decision, now: Date = Date()) {
        guard let i = pending.firstIndex(where: { $0.id == id }), pending[i].questions == nil,
              let conn = connections.removeValue(forKey: id) else { return } // questions are answered via answer(), not Allow/Deny
        let req = pending.remove(at: i)
        if conn.peerGone { // the hook already gave up (timeout) or the terminal answered: this click is stale
            conn.respond(nil)
            record(req, channel: .terminal, decision: "none", now: now)
            refresh()
            return
        }
        if decision == .always, !Tour.isDemo(req.sessionId) { always.insert(req) } // the tour demo must show again next run
        conn.respond(decision.reply)
        record(req, channel: .notch, decision: "\(decision)", now: now)
        refresh()
    }

    /// Answer with a set of labels per question. Single-select needs exactly one; multi-select at least one.
    /// Multi-select labels are joined in the question's option order with ", " (the documented answer format;
    /// not yet verified in a live Claude Code session). An invalid selection changes nothing: the card stays up.
    /// Returns whether the answer was sent.
    @discardableResult
    public func answer(_ id: String, selections: [String: Set<String>], now: Date = Date()) -> Bool {
        guard let i = pending.firstIndex(where: { $0.id == id }), connections[id] != nil, questionInputs[id] != nil,
              let answers = Self.joined(pending[i].questions ?? [], selections) else { return false }
        let conn = connections.removeValue(forKey: id)!
        var input = questionInputs.removeValue(forKey: id)!
        let req = pending.remove(at: i)
        if conn.peerGone { conn.respond(nil); record(req, channel: .terminal, decision: "none", now: now); refresh(); return false }
        input["answers"] = answers
        let reply: [String: Any] = ["behavior": "allow", "updatedInput": input]
        conn.respond(try? JSONSerialization.data(withJSONObject: reply))
        record(req, channel: .notch, decision: "answered", now: now)
        refresh()
        return true
    }

    /// One joined answer string per question, or nil unless every question has a valid selection.
    static func joined(_ qs: [AskQuestion], _ selections: [String: Set<String>]) -> [String: String]? {
        guard !qs.isEmpty else { return nil }
        var out: [String: String] = [:]
        for q in qs {
            guard let chosen = selections[q.question], !chosen.isEmpty, chosen.isSubset(of: Set(q.options.map(\.label))),
                  q.multiSelect || chosen.count == 1 else { return nil }
            out[q.question] = q.options.map(\.label).filter(chosen.contains).joined(separator: ", ")
        }
        return out
    }

    /// "Answer in terminal": reply with nothing so the hook prints nothing and Claude Code shows its own dialog at once.
    public func handBack(_ id: String, now: Date = Date()) {
        guard let i = pending.firstIndex(where: { $0.id == id }), let conn = connections.removeValue(forKey: id) else { return }
        let req = pending.remove(at: i)
        questionInputs.removeValue(forKey: id)
        let stale = conn.peerGone // the hook already gave up or the terminal answered: nothing was handed back
        conn.respond(nil)
        record(req, channel: .terminal, decision: stale ? "none" : "handed_back", now: now)
        refresh()
    }

    /// Drop requests whose hook went away (timeout fallback, or answered in the terminal).
    public func sweep(now: Date = Date()) {
        if peeking, !peek.isPeeking(now: clock()) { refresh() } // an expired peek settles to collapsed
        let gone = pending.filter { connections[$0.id]?.peerGone ?? true }
        if doneItems.contains(where: { now.timeIntervalSince($0.at) > Self.doneSeconds }) { // assign only on change: a no-op write still notifies
            doneItems.removeAll { now.timeIntervalSince($0.at) > Self.doneSeconds }
            refresh()
        }
        guard !gone.isEmpty else { return }
        for r in gone {
            connections.removeValue(forKey: r.id)?.respond(nil); questionInputs.removeValue(forKey: r.id)
            record(r, channel: .terminal, decision: "none", now: now)
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
                let isNew = !doneItems.contains { $0.sessionId == r.id } // a repeat Stop with no activity between is not a new chip
                doneItems.removeAll { $0.sessionId == r.id }
                doneItems.append(DoneItem(sessionId: r.id, project: r.project, branch: r.branch,
                                          files: r.filesEdited.count, added: r.added, removed: r.removed, reply: r.lastReply, prompt: r.lastPrompt, at: now, host: r.host))
                peek.start(now: clock(), hovering: hovering)
                if isNew, !Tour.isDemo(r.id) { onSound?(.done, r.id, r.host ?? payload.host) }
            }
        case "UserPromptSubmit", "SessionEnd", "PreToolUse", "PostToolUse":
            // Only the thread itself moving on (new prompt, tool use after a Stop, or ending) clears its chip; another thread's activity must not.
            doneItems.removeAll { $0.sessionId == payload.sessionId }
            if payload.event == "SessionEnd" { onSessionEnd?(payload.sessionId) }
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
    public let reply: String?
    public let prompt: String?
    public let at: Date
    public var host: HostInfo? = nil

    /// Claude ended on a question: the thread is waiting for you, not just done.
    public var asksYou: Bool { reply?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ?? false }

    /// First non-empty line of the reply, for the one-line glance.
    public var headline: String {
        let line = reply?.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.allSatisfy { "#*-`>".contains($0) } } ?? ""
        return line.isEmpty ? "finished" : line.trimmingCharacters(in: CharacterSet(charactersIn: "#*>` "))
    }

    /// One line beside the camera. Neutral unless the user opted in to seeing the reply there.
    public func glance(showReply: Bool) -> String {
        if showReply { return (asksYou ? "? " : "") + "\(project): \(headline)" }
        return "\(project) · \(asksYou ? "needs you" : "finished")"
    }

    /// "repo · branch", or just the repo.
    public var identity: String { branch.map { "\(project) · \($0)" } ?? project }
}
