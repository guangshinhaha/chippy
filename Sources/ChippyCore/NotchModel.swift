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
    /// Finished threads waiting to be acknowledged. Sticky: they stay until dismissed, the thread moves on, or they age out.
    @Published public private(set) var doneItems: [DoneItem] = []
    /// Questions/approvals that fell back to the terminal (#42). Sticky until the session's next event or `doneSeconds`.
    @Published public private(set) var terminalItems: [TerminalItem] = []
    /// The done chip was clicked: show what the finished threads did.
    @Published public private(set) var doneOpen = false
    /// The done detail is open: the panel grows so the whole reply can be read.
    @Published public private(set) var tall = false
    /// Nothing needs the user: the notch rests as a small tab holding the mascot (never fully hidden, #85).
    @Published public private(set) var resting: Bool
    /// The resting tab was clicked open (#85): Recent list plus the menu gear. Only a click opens it.
    @Published public private(set) var restOpen = false
    /// Last finished threads after their chip went away. Memory only, capped, repo + age only (PDPA).
    @Published public private(set) var recent = RecentList()
    /// Off by default (PDPA): the glance shows only `repo · finished`; the reply stays behind the click.
    @Published public var showReplyInGlance = UserDefaults.standard.bool(forKey: "showReplyInGlance") {
        didSet { UserDefaults.standard.set(showReplyInGlance, forKey: "showReplyInGlance") }
    }
    /// The waiting list (#53) is open: every approval, question and done chip as one row each.
    @Published public private(set) var listOpen = false
    /// Highlighted row while the list is open (arrows move it, Return opens it).
    @Published public private(set) var listSelection: WaitingTarget?
    /// The item the user jumped to from the list; it is shown instead of the default card until it goes away.
    @Published public private(set) var focus: WaitingTarget?
    /// Multi-question progress per request id, so leaving a card keeps what was answered.
    @Published public private(set) var partials: [String: PartialAnswers] = [:]
    /// Asleep after 5 quiet minutes (#54); any hook event wakes it. Only changes the mascot's pose.
    @Published public private(set) var asleep = false
    private var idleClock = IdleClock()
    public static let doneSeconds: TimeInterval = 600
    /// A finished chip is shown compact while peeking, then the island settles to collapsed (chip stays in `doneItems`).
    @Published public private(set) var peeking = false
    private var peek = PeekGate()
    /// Approvals and questions fold into the needs-you badge after 15s (#86); they stay pending and answerable.
    @Published public private(set) var folded = false
    private var fold = NeedsMeFold()
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
        self.resting = density == .collapsed // no chips yet, same as refresh()
        self.always = always
        self.log = log
    }

    private func refresh() {
        let waiting = WaitingList.items(pending: pending, done: doneItems, terminal: terminalItems) // computed once per refresh
        if waiting != waitingItems { waitingItems = waiting }
        guard !debugLock else { resting = false; return }
        if waiting.isEmpty { listOpen = false }
        if listOpen { let sel = WaitingList.reconcile(listSelection, in: waiting); if sel != listSelection { listSelection = sel } }
        if let f = focus, !waiting.contains(where: { $0.target == f }) { // the jumped-to item went away
            focus = nil
            if case .done = f { doneOpen = false } // its detail was what doneOpen showed, whether or not an approval waits
        }
        let pendingIds = Set(pending.map(\.id))
        if partials.keys.contains(where: { !pendingIds.contains($0) }) { partials = partials.filter { pendingIds.contains($0.key) } }
        if doneItems.isEmpty { peek.cancel() }
        if pending.isEmpty { fold.reset(); if folded { folded = false } }
        else if case .pending? = focus { pinFold() } // a card the user jumped to never folds
        else if !folded, fold.isDue(now: clock()) { folded = true }
        if doneItems.isEmpty && terminalItems.isEmpty { doneOpen = false }
        if !pending.isEmpty { restOpen = false } // an approval or question takes over; a passive chip just joins the open panel
        if !pending.isEmpty || doneOpen || listOpen || restOpen { peek.cancel() } // the user (or an approval) took over: no peek to resume on close
        let p = peek.isPeeking(now: clock())
        if p != peeking { peeking = p }
        let live = store.derivedState
        // A terminal chip never hides live work: working wins over it, it wins over done.
        state = !pending.isEmpty ? .needsYou : (live == .working ? .working : (!terminalItems.isEmpty ? .needsYou : (doneItems.isEmpty ? live : .done)))
        // Terminal cards share the panel, so the tall one-card reply view only applies when none are showing.
        tall = !listOpen && (shownDone != nil || (pending.isEmpty && !restOpen && doneOpen && !doneItems.isEmpty && terminalItems.isEmpty))
        let r: Bool
        if (!pending.isEmpty && !folded) || doneOpen || listOpen || restOpen { density = .expanded; r = false }
        else if !pending.isEmpty { density = .collapsed; r = false } // folded: the needs-you badge on the collapsed notch
        else if !terminalItems.isEmpty { density = .compact; r = false }
        else if !doneItems.isEmpty { density = peeking ? .compact : .collapsed; r = false }
        else { density = .collapsed; r = true }
        if r != resting { resting = r }
    }

    /// Everything waiting, in list order (see `WaitingList.items`). Recomputed once per `refresh`.
    @Published public private(set) var waitingItems: [WaitingItem] = []

    /// The approval or question card on screen, or nil while the list or a done detail covers it.
    /// Keyboard shortcuts act on this one only, so a key never answers a card the user cannot see.
    public var shownPending: PendingRequest? {
        guard !listOpen, !folded else { return nil } // a folded card is not on screen, so no key may answer it
        if case .pending(let id)? = focus, let r = pending.first(where: { $0.id == id }) { return r }
        if case .done? = focus { return nil }
        return pending.first
    }

    /// The finished thread the user jumped to from the list (nil otherwise).
    public var shownDone: DoneItem? {
        guard !listOpen, case .done(let id)? = focus else { return nil }
        return doneItems.first { $0.sessionId == id }
    }

    /// Open the waiting list (badge tap, or the header while several wait).
    public func openList() {
        guard !waitingItems.isEmpty else { return }
        listOpen = true
        listSelection = WaitingList.reconcile(listSelection, in: waitingItems)
        refresh()
    }

    public func closeList() {
        guard listOpen else { return }
        listOpen = false
        refresh()
    }

    /// Arrow keys: move the highlighted row.
    public func moveSelection(_ step: Int) {
        guard listOpen else { return }
        listSelection = WaitingList.move(listSelection, in: waitingItems, by: step)
    }

    /// Return: open the highlighted row.
    public func activateSelection() {
        guard listOpen, let t = listSelection else { return }
        activate(t)
    }

    /// Jump to one waiting item: its card, or for a done chip the existing detail.
    public func activate(_ target: WaitingTarget) {
        guard waitingItems.contains(where: { $0.target == target }) else { return }
        listOpen = false; restOpen = false
        focus = target
        if case .pending = target { pinFold() }
        switch target {
        case .done: doneOpen = true
        case .terminal: focus = nil; doneOpen = true // the shared card view lists every terminal chip
        case .pending: doneOpen = false
        }
        refresh()
    }

    /// Remember how far a multi-question card got.
    public func savePartial(_ id: String, step: Int, answers: [String: Set<String>]) {
        guard pending.contains(where: { $0.id == id }) else { return }
        let new = PartialAnswers(step: step, answers: answers)
        // Answering has begun: the card must not fold under the user's hand. Only a real change counts, because the card
        // also saves on disappear (which is what a fold does) and that must not undo the fold.
        if partials[id] != new, new != PartialAnswers() { pinFold() }
        if partials[id] != new { partials[id] = new } // an unchanged write would still notify observers

    }

    /// Count shown on the collapsed notch while finished items wait (nil at 0, "9+" over 9).
    public var badge: String? { PeekGate.badge(count: doneItems.count + (folded ? pending.count : 0)) }

    /// The collapsed badge is the needs-you one (pulsing) while any approval or question is folded.
    public var badgeNeedsYou: Bool { folded && !pending.isEmpty }

    /// When the soonest folded request's hook gives up and the terminal takes over (the badge ring drains to it).
    public var foldedDeadline: (start: Date, end: Date)? {
        guard folded else { return nil }
        return pending.map { r in (r.createdAt, r.createdAt.addingTimeInterval(r.questions != nil ? questionTimeout : approvalTimeout)) }
            .min { $0.1 < $1.1 }.map { (start: $0.0, end: $0.1) }
    }

    /// The user opened the card (or answered part of it): it stays open. Opens a folded card.
    private func pinFold() {
        guard !pending.isEmpty else { return }
        fold.pin()
        if folded { folded = false }
    }

    /// Show the folded card (click on the notch, or a ⌃⌥ key). It never answers by itself, and it never refolds.
    public func unfold() {
        guard folded else { return }
        pinFold()
        refresh()
    }

    /// The pointer entered or left the island: a running peek holds while it is over and resumes when it leaves.
    /// Ignored while expanded, and it never re-opens an expired peek.
    /// Hover never wakes the sleeping mascot (only a click or a hook event does), or the sleeping pose could not be seen.
    public func setHover(_ inside: Bool, now: Date = Date()) {
        hovering = inside
        fold.setHover(inside, now: clock()) // the fold timer holds while the pointer is over the island, expanded or not
        guard density != .expanded else { return }
        peek.setHover(inside, now: clock())
    }

    /// Click on the notch. A waiting approval ignores it. A done chip opens its detail (click again to go back);
    /// otherwise it opens or closes the rest panel (Recent, sessions, menu gear).
    public func toggleOpen(now: Date = Date()) {
        wake(now: now)
        if folded, !listOpen { unfold(); return } // click on the needs-you badge area opens the card
        guard pending.isEmpty, !listOpen else { return }
        if focus != nil { focus = nil; doneOpen = false; refresh(); return } // one gesture folds a jumped-to detail; focus and doneOpen never drift
        if restOpen { restOpen = false; refresh(); return }
        if doneItems.isEmpty && terminalItems.isEmpty { restOpen = true; refresh(); return } // click on the resting tab
        doneOpen.toggle() // a chip is showing: its detail
        refresh()
    }

    /// Click outside the notch: fold an open detail or peek back to its glance. A waiting approval stays.
    public func closeDetail() {
        if listOpen { closeList(); return }
        if case .pending? = focus { return } // the approval or question the user jumped to stays up until answered
        if focus != nil { focus = nil; doneOpen = false; refresh(); return } // back out of a jumped-to done or terminal detail
        guard pending.isEmpty, doneOpen || restOpen else { return }
        doneOpen = false; restOpen = false
        refresh()
    }

    /// Acknowledge one finished thread, or all of them.
    public func dismissDone(_ sessionId: String? = nil, now: Date = Date()) {
        retire(doneItems.filter { sessionId == nil || $0.sessionId == sessionId }, now: now)
        if let sessionId { doneItems.removeAll { $0.sessionId == sessionId } } else { doneItems.removeAll() }
        refresh()
    }

    /// A finished chip is leaving (dismissed or expired): keep a metadata-only trace in Recent.
    private func retire(_ items: [DoneItem], now: Date = Date()) {
        guard !items.isEmpty else { return }
        var r = recent
        for d in items where !Tour.isDemo(d.sessionId) { r.add(RecentItem(d), now: now) }
        if r != recent { recent = r } // assign only on change: a no-op write still notifies
    }

    /// Acknowledge one terminal chip, or all of them.
    public func dismissTerminal(_ sessionId: String? = nil) {
        if let sessionId { terminalItems.removeAll { $0.sessionId == sessionId } } else { terminalItems.removeAll() }
        refresh()
    }

    /// Hook-side waits, mirrored here to tell a timeout from an answer (defaults; the installer writes the same numbers).
    public var approvalTimeout: TimeInterval = TimeInterval(SettingsInstaller.defaultApprovalTimeout)
    public var questionTimeout: TimeInterval = TimeInterval(SettingsInstaller.defaultQuestionTimeout)

    /// The stored session host first, then the one the request arrived with (same order everywhere).
    private func host(for req: PendingRequest) -> HostInfo? {
        sessions.first { $0.id == req.sessionId }?.host ?? req.host
    }

    /// Show `repo · asked in terminal` for this request's session. Metadata only: never the question, command or input.
    private func noteTerminal(_ req: PendingRequest, now: Date) {
        guard !Tour.isDemo(req.sessionId) else { return }
        terminalItems.removeAll { $0.sessionId == req.sessionId }
        terminalItems.append(TerminalItem(sessionId: req.sessionId, project: req.project, at: now, host: host(for: req), tool: req.toolName))
    }

    /// The one path for a request whose hook went away (used by `sweep` and by a stale `resolve`/`answer`).
    /// Rule for the chip: the hook waits `approvalTimeout` / `questionTimeout`. Gone at or after that (give or take
    /// a second) means it timed out unanswered, so the terminal is showing the prompt: chip. Gone earlier means the
    /// terminal was answered (or the session died): no chip. Unsupported questions get theirs in `receiveApproval`.
    private func dropGone(_ r: PendingRequest, now: Date) {
        let wait = r.questions != nil ? questionTimeout : approvalTimeout
        if now.timeIntervalSince(r.createdAt) >= wait - 1 { noteTerminal(r, now: now) }
        connections.removeValue(forKey: r.id)?.respond(nil)
        questionInputs.removeValue(forKey: r.id)
        record(r, channel: .terminal, decision: "none", now: now)
    }

    private static let boundaryEvents: Set<String> = ["UserPromptSubmit", "SessionEnd"]
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]
    /// A terminal chip must outlive a parallel call's tool events, so a matching PostToolUse counts only after this.
    private static let terminalGrace: TimeInterval = 2

    /// User interaction (hover, click) wakes the mascot and restarts the countdown, like an event does.
    public func wake(now: Date = Date()) {
        idleClock.noteEvent(now: now)
        if asleep { asleep = false }
    }

    private func updateSleep(now: Date) {
        let s = SleepPolicy.shouldSleep(state: state, hasDoneChips: !doneItems.isEmpty, clock: idleClock, now: now)
        if s != asleep { asleep = s }
    }

    /// A PermissionRequest hook is waiting on `conn`. Main thread only.
    /// AskUserQuestion is answerable when every question parses (single or multi-select); otherwise no reply, so the terminal handles it.
    public func receiveApproval(_ payload: HookPayload, _ conn: Connection, now: Date = Date()) {
        idleClock.noteEvent(now: now)
        var req = PendingRequest(payload: payload)
        if payload.toolName == "AskUserQuestion" {
            guard req.questions != nil else {
                conn.respond(nil)
                noteTerminal(req, now: req.createdAt)
                refresh()
                return
            }
            questionInputs[req.id] = payload.toolInput
        }
        req.lastPrompt = sessions.first { $0.id == payload.sessionId }?.lastPrompt
        if req.questions == nil, always.contains(req) {
            conn.respond(Decision.allow.reply)
            record(req, channel: .notch, decision: "auto_always", now: req.createdAt)
            return
        }
        // A panel the user opened by click (rest panel, list, done detail) is theirs: the approval joins it and never folds.
        fold.arrive(now: clock(), hovering: hovering, engaged: restOpen || listOpen || doneOpen)
        if folded { folded = false }
        pending.append(req)
        connections[req.id] = conn
        if case .done? = focus { focus = nil; doneOpen = false } // a new blocking request takes over from a done detail
        refresh()
        updateSleep(now: now)
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
            connections[id] = conn
            dropGone(req, now: now)
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
    /// `.refused` consumes nothing (card stays up); `.gone` means the hook had already given up, so the request is dropped.
    public enum Answered: Equatable { case sent, refused, gone }

    @discardableResult
    public func answer(_ id: String, selections: [String: Set<String>], now: Date = Date()) -> Answered {
        guard let i = pending.firstIndex(where: { $0.id == id }), connections[id] != nil, questionInputs[id] != nil,
              let answers = Self.joined(pending[i].questions ?? [], selections) else { return .refused }
        let conn = connections.removeValue(forKey: id)!
        var input = questionInputs.removeValue(forKey: id)!
        let req = pending.remove(at: i)
        if conn.peerGone { connections[id] = conn; dropGone(req, now: now); refresh(); return .gone }
        input["answers"] = answers
        let reply: [String: Any] = ["behavior": "allow", "updatedInput": input]
        conn.respond(try? JSONSerialization.data(withJSONObject: reply))
        record(req, channel: .notch, decision: "answered", now: now)
        refresh()
        return .sent
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
        defer { updateSleep(now: now) } // after expiry + refresh, so it sees the settled state
        if peeking, !peek.isPeeking(now: clock()) { refresh() } // an expired peek settles to collapsed
        if !folded, !pending.isEmpty, fold.isDue(now: clock()) { refresh() } // an expired needs-me timer folds the card
        let gone = pending.filter { connections[$0.id]?.peerGone ?? true }
        let expired = doneItems.contains { now.timeIntervalSince($0.at) > Self.doneSeconds }
            || terminalItems.contains { now.timeIntervalSince($0.at) > Self.doneSeconds }
        var r = recent
        if r.prune(now: now) { recent = r }
        if expired { // assign only on change: a no-op write still notifies
            retire(doneItems.filter { now.timeIntervalSince($0.at) > Self.doneSeconds }, now: now)
            doneItems.removeAll { now.timeIntervalSince($0.at) > Self.doneSeconds }
            terminalItems.removeAll { now.timeIntervalSince($0.at) > Self.doneSeconds }
            refresh()
        }
        guard !gone.isEmpty else { return }
        for r in gone { dropGone(r, now: now) }
        pending.removeAll { r in gone.contains { $0.id == r.id } }
        refresh()
    }

    /// Apply a live hook event. Main thread only.
    public func apply(_ payload: HookPayload, now: Date = Date()) {
        idleClock.noteEvent(now: now)
        store.apply(payload, now: now)
        sessions = store.rows
        // Conservative: tool events are shared with parallel/subagent calls, so only a turn boundary (prompt, Stop, end)
        // clears a terminal chip, or the PostToolUse of the same tool 2s+ after it (the ask was answered). Others stay.
        terminalItems.removeAll { t in
            guard t.sessionId == payload.sessionId else { return false }
            if Self.boundaryEvents.contains(payload.event) || payload.event == "Stop" { return true }
            return payload.event == "PostToolUse" && payload.toolName == t.tool && now.timeIntervalSince(t.at) > Self.terminalGrace
        }
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
        case let e where Self.boundaryEvents.contains(e) || Self.toolEvents.contains(e):
            // Only the thread itself moving on (new prompt, tool use after a Stop, or ending) clears its chip; another thread's activity must not.
            retire(doneItems.filter { $0.sessionId == payload.sessionId }, now: now) // resumed or ended: the finished chip leaves
            doneItems.removeAll { $0.sessionId == payload.sessionId }
            if payload.event == "SessionEnd" { onSessionEnd?(payload.sessionId) }
        default: break
        }
        refresh()
        updateSleep(now: now)
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

/// A question or approval that fell back to the terminal. Holds no content (PDPA, #30): only the repo name.
public struct TerminalItem: Identifiable, Equatable {
    public var id: String { sessionId }
    public let sessionId: String
    /// Last path component of the cwd (worktree-aware), nothing else.
    public let project: String
    public let at: Date
    public var host: HostInfo? = nil
    /// Tool name only (never shown): lets that tool's PostToolUse clear the chip.
    public let tool: String

    public var glance: String { "\(project) · asked in terminal" }
}
