import Foundation

/// Which waiting thing a row points at. Hashable so the list can hold a selection.
public enum WaitingTarget: Hashable {
    case pending(String)   // PendingRequest.id (approval or question)
    case done(String)      // DoneItem.sessionId
}

/// One row of the waiting list (#53). Deliberately carries no question or command text (PDPA #30):
/// only the repo, the kind and when it started waiting.
public struct WaitingItem: Identifiable, Equatable {
    public enum Kind: String { case approval, question, done }
    public let target: WaitingTarget
    public let kind: Kind
    public let repo: String
    public let at: Date
    public var id: WaitingTarget { target }

    public init(target: WaitingTarget, kind: Kind, repo: String, at: Date) {
        self.target = target; self.kind = kind; self.repo = repo; self.at = at
    }
}

/// Pure ordering, selection and labels for the waiting list.
public enum WaitingList {
    /// Last path component of a working directory ("/Users/x/work/api" -> "api"). Never the full path.
    public static func repoName(cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "unknown" : name
    }

    /// Approvals and questions first, because they block an agent (oldest first: the order they queued),
    /// then finished chips, newest first.
    public static func items(pending: [PendingRequest], done: [DoneItem]) -> [WaitingItem] {
        let blocking = pending.enumerated().sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map { _, r in
            WaitingItem(target: .pending(r.id), kind: r.questions != nil ? .question : .approval,
                        repo: repoName(cwd: r.cwd), at: r.createdAt)
        }
        let finished = done.enumerated().sorted { ($0.element.at, $0.offset) > ($1.element.at, $1.offset) }.map { _, d in
            WaitingItem(target: .done(d.sessionId), kind: .done, repo: d.project.isEmpty ? "unknown" : d.project, at: d.at)
        }
        return blocking + finished
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
    public var answers: [String: String] = [:]
    public init(step: Int = 0, answers: [String: String] = [:]) { self.step = step; self.answers = answers }
}
