import Foundation

/// Decides when the user was "away" (#92). Pure: the app feeds it the screen-lock flag and the seconds since the last
/// keyboard or mouse event, with an injected clock. Away means locked, or idle for at least `threshold`.
/// It remembers only a start time, never anything about the sessions.
public struct AwayTracker: Equatable {
    public static let defaultThreshold: TimeInterval = 300
    public let threshold: TimeInterval
    private var awaySince: Date?
    private var lastPoll: Date?

    public init(threshold: TimeInterval = AwayTracker.defaultThreshold) { self.threshold = threshold }

    public var isAway: Bool { awaySince != nil }

    /// Feed one reading. Returns the start of the away period exactly once, at the first reading after the user is back,
    /// and only when that period lasted at least `threshold` (a short lock is not "away"). Otherwise nil.
    public mutating func observe(now: Date, locked: Bool, idle: TimeInterval) -> Date? {
        let idle = max(0, idle)
        // Sleep: nobody polled for longer than the threshold, so the machine was asleep. Away from the previous poll.
        // Only when the idle clock agrees (or the screen is locked): a throttled timer with an active user is not sleep.
        // Accepted (#120): sleep with no lock, then input right at wake, is not away. A lone gap cannot tell it from a throttled
        // timer, and calling every long gap "away" would show a false digest to a user who never left.
        if let last = lastPoll, awaySince == nil {
            let gap = now.timeIntervalSince(last)
            if gap > threshold, locked || idle >= gap * 0.9 { awaySince = last }
        }
        lastPoll = now
        if locked || idle >= threshold {
            // Back-dated by the idle time even when first seen locked, so a finish during the idle lead-in counts.
            let start = now.addingTimeInterval(-idle)
            awaySince = min(awaySince ?? start, start)
            return nil
        }
        guard let since = awaySince else { return nil }
        awaySince = nil
        return now.timeIntervalSince(since) >= threshold ? since : nil
    }
}

/// One line of the while-you-were-away digest. Repo, worktree, status and age only (PDPA #30): no reply, prompt, question or command.
public struct DigestRow: Identifiable, Equatable {
    public enum Status: String { case needsYou, asksYou, finished }
    public let sessionId: String
    public let status: Status
    public let repo: String
    public let worktree: String?
    public let at: Date
    public let resolved: Bool
    /// Where a tap goes while the thread still has a chip or terminal row; nil for a Recent-only row.
    public let target: WaitingTarget?
    public let host: HostInfo?
    public var id: String { sessionId }
}

/// The digest, rebuilt from state the model already holds (terminal asks, finished chips, Recent). Nothing is stored for it
/// beyond the away start time. One row per session; needs-you first (oldest first), then finished (newest first).
public enum AwayDigest {
    public static let maxRows = 5

    public struct Result: Equatable {
        public let rows: [DigestRow]
        public let hidden: Int
        /// Session ids of every finished chip the digest covers (not only the visible rows).
        public let finishedIds: [String]
        public var isEmpty: Bool { rows.isEmpty }
        public var total: Int { rows.count + hidden }
    }

    public static func build(since: Date, until: Date = .distantFuture, terminal: [TerminalItem], done: [DoneItem], recent: [RecentItem],
                             label: (_ cwd: String, _ project: String) -> RepoLabel = { RepoLabel(repo: $1.isEmpty ? "unknown" : $1) },
                             resolved: (_ cwd: String) -> Bool = { _ in true }, cap: Int = maxRows) -> Result {
        var seen = Set<String>()
        var needs: [DigestRow] = [], finished: [DigestRow] = []
        for t in terminal where t.at >= since && t.at <= until && seen.insert(t.sessionId).inserted {
            let l = label(t.cwd, t.project)
            needs.append(DigestRow(sessionId: t.sessionId, status: .needsYou, repo: l.repo, worktree: l.worktree, at: t.at, resolved: resolved(t.cwd),
                                   target: .terminal(t.sessionId), host: t.host))
        }
        for d in done where d.at >= since && d.at <= until && seen.insert(d.sessionId).inserted {
            let l = label(d.cwd, d.project)
            finished.append(DigestRow(sessionId: d.sessionId, status: d.asksYou ? .asksYou : .finished, repo: l.repo, worktree: l.worktree, at: d.at,
                                      resolved: resolved(d.cwd), target: .done(d.sessionId), host: d.host))
        }
        for r in recent where r.at >= since && r.at <= until && seen.insert(r.sessionId).inserted {
            finished.append(DigestRow(sessionId: r.sessionId, status: .finished, repo: r.label.repo, worktree: r.label.worktree, at: r.at,
                                      resolved: r.resolved, target: nil, host: r.host))
        }
        let newest = finished.enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at > $1.element.at : $0.offset < $1.offset }.map(\.element)
        let ordered = needs.sorted { $0.at < $1.at } + newest
        return Result(rows: Array(ordered.prefix(cap)), hidden: max(0, ordered.count - cap),
                      finishedIds: done.filter { d in finished.contains { $0.sessionId == d.sessionId && $0.target != nil } }.map(\.sessionId))
    }
}
