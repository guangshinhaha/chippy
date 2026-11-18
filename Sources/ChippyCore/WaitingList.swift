import Foundation

/// Which waiting thing a row points at. Hashable so the list can hold a selection.
public enum WaitingTarget: Hashable {
    case pending(String)   // PendingRequest.id (approval or question)
    case done(String)      // DoneItem.sessionId
    case terminal(String)  // TerminalItem.sessionId: asked in the terminal
}

/// One row of the waiting list (#53). Deliberately carries no question or command text (PDPA #30):
/// only the repo, the kind, a verb-led label built from tool name / question count, and when it started waiting.
public struct WaitingItem: Identifiable, Equatable {
    public enum Kind: String { case approval, question, done, terminal }
    public let target: WaitingTarget
    public let kind: Kind
    public let repo: String
    /// Linked-worktree folder, shown as a secondary tag only when it differs from the repo's main checkout (#101).
    public let worktree: String?
    public let at: Date
    /// Verb-led action ("Approve Bash?", "Answer 2 questions", "Asked in terminal") or, for finished rows, the outcome.
    public let label: String
    /// Finished thread whose reply ends in a question (#98a): a tag only, it never joins NEEDS YOU.
    public let asksYou: Bool
    /// False while `repo` is still a folder-name fallback (#89): its identity mark must not be stored yet.
    public let resolved: Bool
    public var id: WaitingTarget { target }

    /// Needs you: something the user can act on. Finished rows are FYI.
    public var needsYou: Bool { kind != .done }

    public init(target: WaitingTarget, kind: Kind, repo: String, worktree: String? = nil, at: Date, label: String? = nil, asksYou: Bool = false, resolved: Bool = true) {
        self.target = target; self.kind = kind; self.repo = repo; self.worktree = worktree; self.at = at; self.asksYou = asksYou; self.resolved = resolved
        self.label = label ?? WaitingList.defaultLabel(kind)
    }
}

/// How the list is cut into the two sections, and how much of each fits (#101, sizing per #55).
public struct WaitingLayout: Equatable {
    public let needs: [WaitingItem]
    /// The FINISHED rows that are shown (grouped by repo); the rest are `hiddenFinished`, a "+N more" line nobody can select.
    public let finished: [WaitingItem]
    public let hiddenFinished: Int
    public let totalFinished: Int
    /// Height to give the NEEDS YOU rows; when `needsScrolls`, the rows are taller than this and scroll.
    public let needsHeight: CGFloat
    public let needsScrolls: Bool
    /// The one flat order the arrow keys walk: NEEDS YOU, then the visible FINISHED rows.
    public var selectable: [WaitingItem] { needs + finished }
}

/// Pure ordering, selection and labels for the waiting list.
public enum WaitingList {
    /// Last path component of a working directory ("/Users/x/work/api" -> "api"). Never the full path.
    public static func repoName(cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "unknown" : name
    }

    static func defaultLabel(_ kind: WaitingItem.Kind) -> String {
        switch kind {
        case .approval: return "Approve?"
        case .question: return "Answer a question"
        case .terminal: return "Asked in terminal"
        case .done: return "Finished"
        }
    }

    /// "Approve Bash?" / "Answer 2 questions". Tool name and count only, never the command or the question.
    public static func actionLabel(_ r: PendingRequest) -> String {
        if let n = r.questions?.count { return n == 1 ? "Answer 1 question" : "Answer \(n) questions" }
        if r.isPlanApproval { return "Review plan" }
        return "Approve \(r.toolName)?"
    }

    /// "Needs you next" (#93): approvals, then questions, each by closeness to timeout (createdAt + `timeout`, soonest first),
    /// then terminal fallbacks (oldest first), then finished chips, newest first. Ties keep arrival order (stable).
    /// `timeout` is required: the caller says how long each request waits.
    /// `label` maps (cwd, project) to the row's repo + worktree (#101); the default is the project name alone.
    public static func items(pending: [PendingRequest], done: [DoneItem], terminal: [TerminalItem] = [],
                             timeout: (PendingRequest) -> TimeInterval,
                             label: (_ cwd: String, _ project: String) -> RepoLabel = { RepoLabel(repo: $1.isEmpty ? "unknown" : $1) },
                             resolved: (_ cwd: String) -> Bool = { _ in true }) -> [WaitingItem] {
        // Keys computed once per request (arrival index last, so ties stay stable).
        let keyed = pending.enumerated().map { i, r in (r: r, kind: r.questions != nil ? 1 : 0, due: r.createdAt.addingTimeInterval(timeout(r)), i: i) }
        let blocking = keyed.sorted { ($0.kind, $0.due, $0.i) < ($1.kind, $1.due, $1.i) }.map { $0.r }.map { r -> WaitingItem in
            let l = label(r.cwd, r.project)
            return WaitingItem(target: .pending(r.id), kind: r.questions != nil ? .question : .approval,
                               repo: l.repo, worktree: l.worktree, at: r.createdAt, label: actionLabel(r), resolved: resolved(r.cwd))
        }
        // A request that fell back to the terminal is still waiting on you: it sorts with the blocking ones, after the live cards.
        let inTerminal = terminal.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map { _, t -> WaitingItem in
            let l = label(t.cwd, t.project)
            return WaitingItem(target: .terminal(t.sessionId), kind: .terminal, repo: l.repo, worktree: l.worktree, at: t.at, resolved: resolved(t.cwd))
        }
        let finished = done.enumerated().sorted { ($0.element.at, $0.offset) > ($1.element.at, $1.offset) }.map { _, d -> WaitingItem in
            let l = label(d.cwd, d.project)
            return WaitingItem(target: .done(d.sessionId), kind: .done, repo: l.repo, worktree: l.worktree, at: d.at,
                               label: d.asksYou ? "Asks you" : "Finished", asksYou: d.asksYou, resolved: resolved(d.cwd))
        }
        return blocking + inTerminal + finished
    }

    // Row heights used to decide what fits. The view draws rows at these heights, so the cap holds without measuring.
    public static let needsRowHeight: CGFloat = 50
    public static let finishedRowHeight: CGFloat = 28
    public static let sectionHeaderHeight: CGFloat = 22
    public static let moreRowHeight: CGFloat = 18
    public static let sectionGap: CGFloat = 8
    /// Everything in the expanded card that is not the two sections, built from the same constants NotchView lays out with
    /// (camera spacer, header row, key hint, the stack's spacing, the shape's padding). The camera is the tallest one
    /// (the model does not know the screen), so a real card is never taller than the layout assumed.
    public static let chrome: CGFloat = NotchMetrics.tallestCamera + NotchMetrics.cameraInset + NotchMetrics.cardSpacing
        + NotchMetrics.cardHeaderHeight + NotchMetrics.cardSpacing + sectionGap + NotchMetrics.keyHintHeight + NotchMetrics.shapePadding
    public static let maxFinished = 3

    /// Split into NEEDS YOU and FINISHED and fit them under `NotchMetrics.maxExpandedHeight`.
    /// NEEDS YOU keeps #93 order and is never cut. FINISHED shows at most `maxFinished` rows; when the card would pass the
    /// cap, FINISHED shrinks first (down to just its header and "+N more"), and only then does NEEDS YOU scroll.
    public static func layout(_ items: [WaitingItem], maxFinished: Int = WaitingList.maxFinished,
                              budget: CGFloat = NotchMetrics.maxExpandedHeight - WaitingList.chrome) -> WaitingLayout {
        let needs = items.filter(\.needsYou)
        let finished = items.filter { !$0.needsYou }
        let needsFull = CGFloat(needs.count) * needsRowHeight
        let needsBlock = needs.isEmpty ? 0 : sectionHeaderHeight + needsFull
        func finishedBlock(_ k: Int) -> CGFloat {
            finished.isEmpty ? 0 : sectionHeaderHeight + CGFloat(k) * finishedRowHeight + (finished.count > k ? moreRowHeight : 0)
        }
        func gap() -> CGFloat { needs.isEmpty || finished.isEmpty ? 0 : sectionGap }
        var k = min(maxFinished, finished.count)
        while k > 0, needsBlock + gap() + finishedBlock(k) > budget { k -= 1 }
        let scrolls = needsBlock + gap() + finishedBlock(k) > budget
        // Clamped: the scrolling region never takes more than what the budget leaves (so the card never passes the cap).
        let needsHeight = scrolls ? min(needsFull, max(0, budget - gap() - finishedBlock(k) - sectionHeaderHeight)) : needsFull
        let visible = Array(finished.prefix(k)) // newest k, then grouped so one repo's threads sit together
        return WaitingLayout(needs: needs, finished: groupedByRepo(visible), hiddenFinished: finished.count - k, totalFinished: finished.count,
                             needsHeight: needsHeight, needsScrolls: scrolls)
    }

    /// Rows of one repo together; repos ordered by their newest row, rows keep their order inside a repo.
    static func groupedByRepo(_ rows: [WaitingItem]) -> [WaitingItem] {
        var order: [String] = []
        var buckets: [String: [WaitingItem]] = [:]
        for r in rows {
            if buckets[r.repo] == nil { order.append(r.repo) }
            buckets[r.repo, default: []].append(r)
        }
        return order.flatMap { buckets[$0] ?? [] }
    }

    /// Arrow-key movement: clamps at both ends (no wrap, so the user always knows where the edge is).
    /// No selection yet starts at the first row going down, the last going up. Nil when the list is empty.
    public static func move(_ selected: WaitingTarget?, in items: [WaitingItem], by step: Int) -> WaitingTarget? {
        guard !items.isEmpty else { return nil }
        guard let selected, let i = items.firstIndex(where: { $0.target == selected }) else {
            return (step < 0 ? items.last : items.first)?.target
        }
        return items[min(max(i + step, 0), items.count - 1)].target
    }

    /// Keep a selection valid as items come and go: unchanged if still there, else the first row.
    public static func reconcile(_ selected: WaitingTarget?, in items: [WaitingItem]) -> WaitingTarget? {
        if let selected, items.contains(where: { $0.target == selected }) { return selected }
        return items.first?.target
    }

    /// "now", "42s", "5m", "2h", "3d". Never negative.
    public static func age(since at: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(at)))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// Answers given so far on a multi-question card. Kept in the model so leaving the card (to the list, to another
/// item) does not lose them. In memory only; dropped when the request is resolved.
public struct PartialAnswers: Equatable {
    public var step = 0
    public var answers: [String: Set<String>] = [:]
    public init(step: Int = 0, answers: [String: Set<String>] = [:]) { self.step = step; self.answers = answers }
}
