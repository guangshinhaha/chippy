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
    /// Away detection (#92): the app says whether the screen is locked and how long the keyboard and mouse were idle.
    /// Default is never away, so tests and the gallery are unaffected.
    public var awaySignal: () -> (locked: Bool, idle: TimeInterval) = { (false, 0) }
    private var awayTracker = AwayTracker()
    /// Start of the last away period that left something to report. The only thing kept for the digest (the rows are
    /// rebuilt from state already held), so nothing new is stored, logged or sent (PDPA). Cleared once seen.
    @Published public private(set) var awaySince: Date?
    private var digestShown = false
    public static let doneSeconds: TimeInterval = 600
    /// A terminal row is a guess (#101): it clears on a turn boundary, a matching PostToolUse, or "Handled". If none arrives
    /// it is dropped after this long (30 min, the Recent TTL), longer than finished chips because it is something to act on.
    public static let terminalSeconds: TimeInterval = 1800
    /// A finished chip is shown compact while peeking, then the island settles to collapsed (chip stays in `doneItems`).
    @Published public private(set) var peeking = false
    private var peek = PeekGate()
    /// Approvals and questions fold into the needs-you badge after 15s (#86); they stay pending and answerable.
    @Published public private(set) var folded = false
    /// One timer per request, so a later request never restarts an earlier one's fold (the oldest decides).
    private var folds: [String: NeedsMeFold] = [:]
    /// Last pointer state from the panel, kept even while expanded so a new peek can start from it.
    private var hovering = false
    private let clock: () -> TimeInterval
    private var store = SessionStore()
    private var connections: [String: Connection] = [:]
    private var echoInputs: [String: [String: Any]] = [:]
    /// Sound hook (#67): fired for a new approval/question and a finished chip. The app decides whether to play.
    public var onSound: ((SoundKind, _ sessionId: String, _ host: HostInfo?, _ quiet: SilenceState) -> Void)?
    /// Quiet state (#95), asked at event time. While quiet a new approval arrives folded on the badge and a finished
    /// chip does not peek. Nothing is dropped: requests stay pending and the hook timeout still falls back to the terminal.
    public var silence: () -> SilenceState = { SilenceState() }
    /// Requests that arrived folded only because it was quiet (#95). When quiet ends they are shown (and sound once).
    private var quietFolded: Set<String> = []
    /// Fired when a session ends, so callers can drop per-session state.
    public var onSessionEnd: ((String) -> Void)?
    private let always: AlwaysStore
    private let log: EventLog
    /// Repo + worktree labels from git, resolved off the main thread and cached per cwd (#101).
    public let identities: RepoIdentityCache
    /// Colour, shape and letter per resolved repo (#89). Worktrees of one repo share it; the worktree is only a sub-label.
    public let marks = IdentityBook()

    public init(state: ChippyState = .idle, density: Density = .collapsed,
                always: AlwaysStore = AlwaysStore(), log: EventLog = EventLog(),
                clock: @escaping () -> TimeInterval = PeekGate.monotonicNow,
                identities: RepoIdentityCache = RepoIdentityCache(),
                tick: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.clock = clock
        self.identities = identities
        self.state = state
        self.density = density
        self.resting = density == .collapsed // no chips yet, same as refresh()
        self.always = always
        self.log = log
        self.tick = tick
        // A label that changed after git was read redraws the rows. Observers add up (a shared cache keeps every owner's),
        // and a burst of resolutions becomes one refresh per runloop tick.
        identities.addObserver { [weak self] in self?.labelsChanged() }
    }

    private let tick: (@escaping () -> Void) -> Void
    private var labelRefreshQueued = false
    /// Bumps when a resolved repo label changed, so views that show a label outside the waiting list (Recent) redraw.
    @Published public private(set) var labelEpoch = 0

    private var refreshing = false
    private var refreshAgain = false

    private func labelsChanged() {
        if refreshing { refreshAgain = true; return } // an inline tick must not recurse into refresh
        guard !labelRefreshQueued else { return }
        labelRefreshQueued = true
        tick { [weak self] in
            guard let self else { return }
            self.labelRefreshQueued = false
            self.labelEpoch += 1
            self.refresh()
        }
    }

    /// The one repo label for a cwd, as list rows show it: cached git result, or the folder-name fallback while it loads.
    public func repoLabel(cwd: String, project: String) -> RepoLabel { identities.label(cwd: cwd, project: project) }

    /// The identity for a cwd's resolved repo, consistent with the label every list and card shows.
    /// Until the cache has resolved the cwd the raw hash slot is used and nothing is stored, so the mark cannot flip later (#89).
    public func identity(cwd: String, project: String) -> SessionIdentity {
        let label = repoLabel(cwd: cwd, project: project)
        return marks.identity(for: label, resolved: identities.isResolved(cwd: cwd))
    }
    public func identity(item: WaitingItem) -> SessionIdentity { marks.identity(repo: item.repo, resolved: item.resolved) }

    /// Whose request the needs-you badge points at: the rank-first needs-you item (the one a badge tap opens).
    public var badgeIdentity: SessionIdentity? {
        guard badgeNeedsYou, let top = waitingItems.first(where: { $0.needsYou }) else { return nil }
        return identity(item: top)
    }

    /// The repo name the badge's mark stands for (spoken by VoiceOver).
    public var badgeRepo: String? {
        guard badgeNeedsYou else { return nil }
        return waitingItems.first(where: { $0.needsYou })?.repo
    }

    /// While-you-were-away digest (#92): nil when none is pending or nothing in it is left to report. Passive: it only
    /// sets a dot and fills the rest panel the user opens; it never pops, folds anything open or plays a sound.
    public var awayDigest: AwayDigest.Result? {
        guard let since = awaySince else { return nil }
        let d = AwayDigest.build(since: since, terminal: terminalItems, done: doneItems, recent: recent.items,
                                 label: { [identities] cwd, project in identities.label(cwd: cwd, project: project) },
                                 resolved: { [identities] in identities.isResolved(cwd: $0) })
        return d.isEmpty ? nil : d
    }

    public func identity(row: DigestRow) -> SessionIdentity { marks.identity(repo: row.repo, resolved: row.resolved) }

    /// Open the rest panel on the digest (the dot's tap). An approval or question on screen takes precedence.
    public func openDigest() {
        guard awayDigest != nil, pending.isEmpty else { return }
        listOpen = false; focus = nil; doneOpen = false; restOpen = true
        refresh()
    }

    /// Dismiss: the digest's finished chips move to Recent (same as "Clear all" for those), terminal asks stay (they
    /// are still needs-you, cleared by "Handled"), and the digest is gone.
    public func dismissAwayDigest(now: Date = Date()) {
        if let d = awayDigest {
            for r in d.rows where r.status != .needsYou && doneItems.contains(where: { $0.sessionId == r.sessionId }) { dismissDone(r.sessionId, now: now) }
        }
        awaySince = nil; digestShown = false
        refresh()
    }

    /// Feed the away tracker; a qualifying return sets the digest start (the earliest unseen one wins).
    private func observeAway(now: Date) {
        let s = awaySignal()
        guard let since = awayTracker.observe(now: now, locked: s.locked, idle: s.idle) else { return }
        let start = min(awaySince ?? since, since)
        let had = awaySince
        awaySince = start
        if awayDigest == nil { awaySince = had } // nothing to report: no dot
        else { digestShown = false; refresh() }
    }

    private func refresh() {
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain { refreshAgain = false; labelsChanged() }
        }
        let waiting = WaitingList.items(pending: pending, done: doneItems, terminal: terminalItems, timeout: timeout(for:),
                                        label: { [identities] cwd, project in identities.label(cwd: cwd, project: project) }, // computed once per refresh
                                        resolved: { [identities] in identities.isResolved(cwd: $0) })
        if waiting != waitingItems {
            waitingItems = waiting
            waitingLayout = WaitingList.layout(waiting)
            let byId = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            rankedPending = waiting.compactMap { if case .pending(let id) = $0.target { return byId[id] } else { return nil } } // stored: not rebuilt per access
        }
        guard !debugLock else { resting = false; return }
        if waiting.isEmpty { listOpen = false }
        if listOpen { let sel = WaitingList.reconcile(listSelection, in: waitingLayout.selectable); if sel != listSelection { listSelection = sel } }
        if let f = focus, !waiting.contains(where: { $0.target == f }) { // the jumped-to item went away
            focus = nil
            if case .done = f { doneOpen = false } // its detail was what doneOpen showed, whether or not an approval waits
        }
        let pendingIds = Set(pending.map(\.id))
        if partials.keys.contains(where: { !pendingIds.contains($0) }) { partials = partials.filter { pendingIds.contains($0.key) } }
        if doneItems.isEmpty { peek.cancel() }
        if !quietFolded.isEmpty { quietFolded.formIntersection(pendingIds) }
        if folds.keys.contains(where: { !pendingIds.contains($0) }) {
            folds = folds.filter { pendingIds.contains($0.key) }
        }
        if !expandedPlans.isSubset(of: pendingIds) { expandedPlans.formIntersection(pendingIds) }
        if pending.isEmpty { if folded { folded = false } }
        else if !folded, foldDue(now: clock()) { folded = true }
        // The visible card is sticky: rank only picks one when nothing is on screen (first show, after an answer, after a fold).
        if folded || pending.isEmpty { shownId = nil }
        else if case .done? = focus { shownId = nil } // leaving for a done detail: back to the queue head afterwards
        else if case .pending(let id)? = focus { shownId = id } // a jump makes that card the remembered one, so answering it falls back to rank-first
        else if shownId.map({ id in !pendingIds.contains(id) }) ?? true { shownId = rankedPending.first?.id }
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
        if restOpen, awayDigest != nil { digestShown = true }
        else if !restOpen, digestShown { digestShown = false; awaySince = nil } // seen: the dot clears when its panel closes
    }

    /// Everything waiting, in list order (see `WaitingList.items`). Recomputed once per `refresh`.
    @Published public private(set) var waitingItems: [WaitingItem] = []

    /// The list cut into NEEDS YOU and FINISHED, with the FINISHED cap applied (#101). Recomputed with `waitingItems`.
    @Published public private(set) var waitingLayout = WaitingLayout(needs: [], finished: [], hiddenFinished: 0, totalFinished: 0, needsHeight: 0, needsScrolls: false)

    /// The approval or question card on screen, or nil while the list or a done detail covers it.
    /// Keyboard shortcuts act on this one only, so a key never answers a card the user cannot see.
    public var shownPending: PendingRequest? {
        guard !listOpen, !folded else { return nil } // a folded card is not on screen, so no key may answer it
        if case .pending(let id)? = focus, let r = pending.first(where: { $0.id == id }) { return r }
        if case .done? = focus { return nil }
        if let id = shownId, let r = pending.first(where: { $0.id == id }) { return r } // sticky: a new arrival never swaps it
        return rankedPending.first
    }

    /// The card remembered as on screen while it is still pending (nil when nothing is shown). Only `refresh` sets it.
    private var shownId: String?

    /// Pending requests in rank order (approvals, then questions, each soonest-timeout first; see `WaitingList.items`).
    /// Computed once per `refresh`. Rank decides which card appears when none is shown, the list order, the badge tap
    /// and the "n of N" index; it does not swap a card already on screen, and it does not pick the fold timer's owner.
    public private(set) var rankedPending: [PendingRequest] = []

    /// The finished thread the user jumped to from the list (nil otherwise).
    public var shownDone: DoneItem? {
        guard !listOpen, case .done(let id)? = focus else { return nil }
        return doneItems.first { $0.sessionId == id }
    }

    /// Header text for the expanded card, derived from what the body actually shows (#96), never from the overall `state`.
    /// Precedence mirrors the body: list > answerable card (pending) > jumped-to done detail > Recent (no chips)
    /// > terminal chips > done chips > state. A terminal chip is passive (nothing to answer here), so it never says "Needs you".
    public var headerTitle: String {
        if listOpen { return "Waiting · \(waitingItems.count)" }
        if let r = shownPending {
            let n = rankedPending.count
            let at = rankedPending.firstIndex { $0.id == r.id } ?? 0
            return n > 1 ? "Needs you · \(at + 1) of \(n)" : "Needs you"
        }
        if shownDone != nil { return pending.isEmpty ? "Done" : "Finished" }
        if restOpen, awayDigest != nil { return "While you were away" }
        if restOpen && doneItems.isEmpty && terminalItems.isEmpty { return "Recent" }
        if !terminalItems.isEmpty { return "Asked in terminal" }
        if !doneItems.isEmpty { return ChippyState.done.title }
        return state.title
    }

    /// Open the waiting list (badge tap, or the header while several wait).
    public func openList() {
        guard !waitingItems.isEmpty else { return }
        // No pin: folding just pauses while the list is open (foldDue), and closeList gives unpinned cards a fresh timer.
        listOpen = true
        listSelection = WaitingList.reconcile(listSelection, in: waitingLayout.selectable)
        refresh()
    }

    /// Badge tap: open the top-ranked "needs you" item by hand (#93). It pins only that card, like a list jump (unfold pins all).
    /// With only finished chips, open the list.
    public func openBadge() {
        if badgeNeedsYou, let top = waitingItems.first(where: { if case .pending = $0.target { return true } else { return false } }) { activate(top.target) }
        else if awayDigest != nil { openDigest() }
        else { openList() }
    }

    public func closeList() {
        guard listOpen else { return }
        listOpen = false
        for id in Array(folds.keys) { folds[id]?.arrive(now: clock(), hovering: hovering, engaged: false) } // pinned ones stay pinned
        refresh()
    }

    /// Arrow keys: move the highlighted row.
    public func moveSelection(_ step: Int) {
        guard listOpen else { return }
        listSelection = WaitingList.move(listSelection, in: waitingLayout.selectable, by: step) // one flat order; "+N more" is not in it
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
        if case .pending(let id) = target { open(ids: [id]) }
        switch target {
        case .done: doneOpen = true
        case .terminal: focus = nil; doneOpen = true // the shared card view lists every terminal chip
        case .pending: doneOpen = false
        }
        refresh()
    }

    /// Remember how far a multi-question card got.
    /// `byUser` is false for the card's own re-seed or disappear saves, which must never pin it (a fold is a disappear).
    public func savePartial(_ id: String, step: Int, answers: [String: Set<String>], byUser: Bool = true) {
        guard pending.contains(where: { $0.id == id }) else { return }
        let new = PartialAnswers(step: step, answers: answers)
        if byUser { folds[id]?.pin() } // any real interaction (step, pick, toggle, clear) means the user is engaged
        if partials[id] != new { partials[id] = new } // an unchanged write would still notify observers

    }

    /// Plan cards the user has expanded (#91). The hotkey approves a plan only from an expanded card, unless it is short enough
    /// to be fully shown folded.
    @Published public private(set) var expandedPlans: Set<String> = []
    public func setPlanExpanded(_ id: String, _ on: Bool) {
        guard pending.contains(where: { $0.id == id }) else { return }
        if on { expandedPlans.insert(id) } else { expandedPlans.remove(id) }
        if on { folds[id]?.pin() }
    }
    /// May ⌃⌥Y approve this card? Any non-plan card yes. A truncated plan never (expanded or not: part of it is not readable
    /// here, so the user must click "Approve (partly shown)"). Otherwise a plan only when nothing is folded away from the reader.
    public func hotkeyMayApprove(_ req: PendingRequest) -> Bool {
        guard req.isPlanApproval else { return true }
        guard let plan = req.plan else { return false }
        if plan.truncated { return false }
        return !plan.canExpand || expandedPlans.contains(req.id)
    }

    /// Experimental (#91): off by default. While off, ExitPlanMode goes to the terminal prompt untouched.
    public var planCardEnabled = false

    /// Count shown on the collapsed notch: needs-you only (#101), i.e. folded approvals and questions plus terminal asks
    /// (nil at 0, "9+" over 9). Finished chips never count.
    public var badge: String? { PeekGate.badge(count: (folded ? pending.count : 0) + terminalItems.count) }

    /// Only finished items wait: a plain dot (no number), so a tap still opens something without implying work for you.
    /// Never while an approval or question is pending (an unfolded card is on screen, so the notch is not at rest).
    /// VoiceOver label for the dot: a finished thread that asks something is not "nothing needs you".
    public var badgeDotLabel: String {
        if let d = awayDigest, doneItems.isEmpty { return "While you were away: \(d.total) \(d.total == 1 ? "update" : "updates")" }
        return waitingItems.contains { $0.kind == .done && $0.asksYou } ? "Finished threads waiting; one asks you" : "Finished threads waiting, nothing needs you"
    }
    public var badgeDot: Bool { badge == nil && pending.isEmpty && (!doneItems.isEmpty || awayDigest != nil) }

    /// The collapsed badge is the needs-you one (pulsing) while any approval or question is folded, or a question
    /// fell back to the terminal: both are the same "needs you" to the user.
    public var badgeNeedsYou: Bool { (folded && !pending.isEmpty) || !terminalItems.isEmpty }

    /// A terminal-only badge has no deadline (the hook already gave up), so it pulses without a ring.
    /// When the soonest folded request's hook gives up and the terminal takes over (the badge ring drains to it).
    /// Only requests with a known wait count; one without does not hide the others' deadline.
    public var foldedDeadline: (start: Date, end: Date)? {
        guard folded else { return nil }
        return pending.compactMap { r in knownTimeout(for: r).map { (r.createdAt, r.createdAt.addingTimeInterval($0)) } }
            .min { $0.1 < $1.1 }.map { (start: $0.0, end: $0.1) }
    }

    /// Pin these requests as opened by hand, and show the card if the notch was folded.
    private func open(ids: [String]) {
        for id in ids where pending.contains(where: { $0.id == id }) { folds[id]?.pin() }
        if folded { folded = false }
        quietFolded.subtract(ids) // only the ones opened: others stay marked until quiet ends
    }

    /// The oldest request decides: it is due and the user has pinned none, so a later request never restarts an earlier
    /// one's timer. A pinned card (opened by hand) is never folded away; while one exists the panel stays on it, the older
    /// due requests wait behind it in the list, and the moment it is answered the panel folds (the oldest is due).
    /// Never while the list is open.
    private func foldDue(now: TimeInterval) -> Bool {
        guard !listOpen, let oldest = pending.first, !folds.values.contains(where: \.isPinned) else { return false }
        return folds[oldest.id]?.isDue(now: now) ?? false
    }

    /// Quiet ended (Focus off, screen unlocked): requests that were folded only because of quiet get their normal
    /// treatment, a fresh fold timer, and sound once. Called from `sweep`; cheap when nothing was quiet-folded.
    func reevaluateQuiet() {
        guard !quietFolded.isEmpty else { return }
        let quiet = silence()
        guard !quiet.isQuiet else { return }
        let ids = pending.filter { quietFolded.contains($0.id) }
        quietFolded.subtract(ids.map(\.id))
        guard !ids.isEmpty else { return }
        if folded { // already unfolded by hand: nothing to re-show, but each still sounds once below
            folded = false
            for id in Array(folds.keys) { folds[id]?.arrive(now: clock(), hovering: hovering, engaged: false) }
            refresh()
        }
        for r in ids where !Tour.isDemo(r.sessionId) {
            onSound?(.needsYou, r.sessionId, sessions.first { $0.id == r.sessionId }?.host, quiet)
        }
    }

    /// Hook-side wait for this request, so a card can show when the terminal takes over.
    /// The wait the relay reported, or nil from an older relay: then nothing is dropped on a timeout (only a hang-up ends
    /// the request), and no ring or "times out" text is shown, because the real wait may be custom.
    public func knownTimeout(for r: PendingRequest) -> TimeInterval? { r.waitSeconds }

    /// The relay's own reported wait wins (a custom `--timeout`); the defaults cover an older relay.
    public func timeout(for r: PendingRequest) -> TimeInterval { r.waitSeconds ?? (r.questions != nil ? questionTimeout : approvalTimeout) }

    /// Show the folded card (click on the notch). No ⌃⌥ key does this: keys exist only for a card that is on screen.
    /// It never answers by itself, and it never refolds.
    public func unfold() {
        guard folded else { return }
        open(ids: pending.map(\.id))
        refresh()
    }

    /// The pointer entered or left the island: a running peek holds while it is over and resumes when it leaves.
    /// Ignored while expanded, and it never re-opens an expired peek.
    /// Hover never wakes the sleeping mascot (only a click or a hook event does), or the sleeping pose could not be seen.
    public func setHover(_ inside: Bool, now: Date = Date()) {
        hovering = inside
        for id in Array(folds.keys) { folds[id]?.setHover(inside, now: clock()) } // the timers hold while the pointer is over the island, expanded or not
        if !pending.isEmpty { refresh() } // a fold that came due (or resumed) lands now, not at the next sweep
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
        terminalItems.append(TerminalItem(sessionId: req.sessionId, project: req.project, at: now, host: host(for: req), tool: req.toolName, cwd: req.cwd))
        // The row the user had selected turned into this terminal row (new id): selection follows it, not the top of the list.
        if listSelection == .pending(req.id) { listSelection = .terminal(req.sessionId) }
    }

    /// The one path for a request whose hook went away (used by `sweep` and by a stale `resolve`/`answer`).
    /// Rule for the chip: the hook waits `approvalTimeout` / `questionTimeout`. Gone at or after that (give or take
    /// a second) means it timed out unanswered, so the terminal is showing the prompt: chip. Gone earlier means the
    /// terminal was answered (or the session died): no chip. Unsupported questions get theirs in `receiveApproval`.
    private func dropGone(_ r: PendingRequest, now: Date) {
        let wait = timeout(for: r)
        if now.timeIntervalSince(r.createdAt) >= wait - 1 { noteTerminal(r, now: now) }
        connections.removeValue(forKey: r.id)?.respond(nil)
        echoInputs.removeValue(forKey: r.id)
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
            echoInputs[req.id] = payload.toolInput
        }
        // ExitPlanMode is allowed only with its own input echoed back as updatedInput (docs: a bare allow is not enough).
        // Flag off or no parseable plan: never a generic Allow card for a plan; the terminal prompt handles it.
        if req.isPlanApproval {
            guard planCardEnabled, req.plan != nil else {
                conn.respond(nil)
                noteTerminal(req, now: req.createdAt)
                record(req, channel: .terminal, decision: "none", now: req.createdAt)
                refresh()
                return
            }
            echoInputs[req.id] = payload.toolInput
        }
        req.lastPrompt = sessions.first { $0.id == payload.sessionId }?.lastPrompt
        if req.questions == nil, !req.isPlanApproval, always.contains(req) {
            conn.respond(Decision.allow.reply)
            record(req, channel: .notch, decision: "auto_always", now: req.createdAt)
            return
        }
        if case .done? = focus { focus = nil }
        let wasDoneOpen = doneOpen
        doneOpen = false // a new blocking request takes over from a done detail: it is not a panel the user opened for this
        // A rest panel or list the user opened by click is theirs: the approval joins it and never folds.
        let engaged = restOpen || listOpen
        // Read quiet state once for this event; the same value goes to the model's decisions and to the sound hook.
        let quiet = silence()
        let quietNow = quiet.isQuiet
        let foldQuiet = quietNow && !Tour.isDemo(req.sessionId) // the onboarding tour must work during Focus/lock
        // Something is on screen or in the user's hands: a card showing, a pinned card, an opened list or rest panel.
        let onScreen = (!pending.isEmpty && !folded) || engaged || wasDoneOpen || folds.values.contains(where: \.isPinned)
        let keepFolded = foldQuiet && folded && !onScreen
        if folded, !keepFolded { // a new request auto-expands; the earlier ones, shown again with it, get a fresh timer
            folded = false
            if !quietNow { quietFolded = [] } // still quiet (a demo card revealed them): they keep their once-sound for when it ends
            for id in Array(folds.keys) { folds[id]?.arrive(now: clock(), hovering: hovering, engaged: false) }
        }
        var f = NeedsMeFold()
        f.arrive(now: clock(), hovering: hovering, engaged: engaged)
        folds[req.id] = f
        pending.append(req)
        connections[req.id] = conn
        // Quiet (Focus/locked): do not pop the card. A card or list the user opened by hand (engaged) stays as it is.
        // Never folds a card that is already on screen or pinned, only a notch showing nothing (or already folded).
        if foldQuiet, !onScreen { folded = true; quietFolded.insert(req.id) }
        refresh()
        updateSleep(now: now)
        if !Tour.isDemo(req.sessionId) {
            onSound?(.needsYou, req.sessionId, sessions.first { $0.id == req.sessionId }?.host ?? payload.host, quiet)
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
              !(pending[i].isPlanApproval && decision == .always), // a plan is never approved "always"
              let conn = connections.removeValue(forKey: id) else { return } // questions are answered via answer(), not Allow/Deny
        let req = pending.remove(at: i)
        if conn.peerGone { // the hook already gave up (timeout) or the terminal answered: this click is stale
            connections[id] = conn
            dropGone(req, now: now)
            refresh()
            return
        }
        if decision == .always, !Tour.isDemo(req.sessionId) { always.insert(req) } // the tour demo must show again next run
        if req.isPlanApproval {
            let echo = echoInputs.removeValue(forKey: id)
            let data = echo.flatMap { Self.planReply(decision, input: $0) }
            conn.respond(data) // nil (no echo, or unserialisable) leaves the terminal prompt to answer
            record(req, channel: data == nil ? .terminal : .notch, decision: data == nil ? "none" : "\(decision)", now: now)
            refresh()
            return
        } else {
            conn.respond(decision.reply)
        }
        record(req, channel: .notch, decision: "\(decision)", now: now)
        refresh()
    }

    /// Reply for ExitPlanMode. Approve echoes the original tool input as `updatedInput`; Keep planning is a deny with a fixed
    /// message (no plan text, no interrupt) that goes to Claude. Live behaviour of both is unverified (see the spikes doc).
    static func planReply(_ d: Decision, input: [String: Any]) -> Data? {
        let o: [String: Any] = d == .deny
            ? ["behavior": "deny", "message": "The user chose to keep planning. Revise the plan and propose it again."]
            : ["behavior": "allow", "updatedInput": input]
        guard JSONSerialization.isValidJSONObject(o) else { return nil } // invalid types raise, not throw
        return try? JSONSerialization.data(withJSONObject: o)
    }

    /// Answer with a set of labels per question. Single-select needs exactly one; multi-select at least one.
    /// Multi-select labels are joined in the question's option order with ", " (the documented answer format;
    /// not yet verified in a live Claude Code session). An invalid selection changes nothing: the card stays up.
    /// `.refused` consumes nothing (card stays up); `.gone` means the hook had already given up, so the request is dropped.
    public enum Answered: Equatable { case sent, refused, gone }

    @discardableResult
    public func answer(_ id: String, selections: [String: Set<String>], now: Date = Date()) -> Answered {
        guard let i = pending.firstIndex(where: { $0.id == id }), connections[id] != nil, echoInputs[id] != nil,
              let answers = Self.joined(pending[i].questions ?? [], selections) else { return .refused }
        let conn = connections.removeValue(forKey: id)!
        var input = echoInputs.removeValue(forKey: id)!
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
        echoInputs.removeValue(forKey: id)
        let stale = conn.peerGone // the hook already gave up or the terminal answered: nothing was handed back
        conn.respond(nil)
        record(req, channel: .terminal, decision: stale ? "none" : "handed_back", now: now)
        refresh()
    }

    /// Drop requests whose hook went away (timeout fallback, or answered in the terminal).
    public func sweep(now: Date = Date()) {
        observeAway(now: now)
        reevaluateQuiet()
        defer { updateSleep(now: now) } // after expiry + refresh, so it sees the settled state
        if peeking, !peek.isPeeking(now: clock()) { refresh() } // an expired peek settles to collapsed
        if !folded, !pending.isEmpty, foldDue(now: clock()) { refresh() } // an expired needs-me timer folds the card
        // Gone: the hook hung up, or its reported wait is over (hover only holds the fold, never the hook's deadline).
        // With no reported wait (older relay) only a hang-up counts.
        let gone = pending.filter { r in (connections[r.id]?.peerGone ?? true) || (knownTimeout(for: r).map { now >= r.createdAt.addingTimeInterval($0) } ?? false) }
        let expired = doneItems.contains { now.timeIntervalSince($0.at) > Self.doneSeconds }
            || terminalItems.contains { now.timeIntervalSince($0.at) > Self.terminalSeconds }
        var r = recent
        if r.prune(now: now) { recent = r }
        if expired { // assign only on change: a no-op write still notifies
            retire(doneItems.filter { now.timeIntervalSince($0.at) > Self.doneSeconds }, now: now)
            doneItems.removeAll { now.timeIntervalSince($0.at) > Self.doneSeconds }
            terminalItems.removeAll { now.timeIntervalSince($0.at) > Self.terminalSeconds }
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
                                          files: r.filesEdited.count, added: r.added, removed: r.removed, reply: r.lastReply, prompt: r.lastPrompt, at: now, host: r.host, cwd: r.cwd))
                let quiet = silence()
                if !quiet.isQuiet { peek.start(now: clock(), hovering: hovering) }
                if isNew, !Tour.isDemo(r.id) { onSound?(.done, r.id, r.host ?? payload.host, quiet) }
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
    /// Already cleaned of system markup where it is stored (SessionStore).
    public let prompt: String?
    public let at: Date
    public var host: HostInfo? = nil
    /// Working directory, kept only to resolve the repo + worktree label (#101); never shown.
    public let cwd: String
    /// Claude ended on a question: the thread is waiting for you, not just done. Computed once, at build.
    public let asksYou: Bool
    /// The closing question as its own line (#98a); nil when there is none. Computed once, at build.
    public let decision: String?
    /// The reply with the decision sentence trimmed off, for when the decision is shown on its own line.
    public let replyWithoutDecision: String

    public init(sessionId: String, project: String, branch: String?, files: Int, added: Int, removed: Int,
                reply: String?, prompt: String?, at: Date, host: HostInfo? = nil, cwd: String = "") {
        self.sessionId = sessionId; self.project = project; self.branch = branch
        self.files = files; self.added = added; self.removed = removed
        self.reply = reply; self.prompt = prompt; self.at = at; self.host = host; self.cwd = cwd
        let a = SummaryCleaner.analyze(reply)
        asksYou = a.asksYou; decision = a.decision; replyWithoutDecision = a.rest
    }

    /// First non-empty line of the reply, for the one-line glance.
    public var headline: String {
        let line = reply?.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.allSatisfy { "#*-`>".contains($0) } } ?? ""
        return line.isEmpty ? "finished" : line.trimmingCharacters(in: CharacterSet(charactersIn: "#*>` "))
    }

    /// One line beside the camera. Neutral unless the user opted in to seeing the reply there.
    /// `repo` is the resolved label (same as the list rows); it defaults to the project name.
    public func glance(showReply: Bool, repo: String? = nil) -> String {
        let r = repo ?? project
        if showReply { return (asksYou ? "? " : "") + "\(r): \(headline)" }
        return "\(r) · \(asksYou ? "needs you" : "finished")"
    }

    /// "repo · branch", or just the repo.
    public var identity: String { identityLine(repo: project) }
    public func identityLine(repo: String) -> String { branch.map { "\(repo) · \($0)" } ?? repo }
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
    /// Working directory, kept only to resolve the repo + worktree label (#101); never shown.
    public var cwd = ""

    public var glance: String { glance(repo: project) }
    public func glance(repo: String) -> String { "\(repo) · asked in terminal" }
}
