import Foundation

/// One entry of the Recent list (#85). By construction it holds no reply, prompt, question, command or full path (PDPA #30):
/// only the repo label, when the thread finished, and which app hosts it (for the Open button).
public struct RecentItem: Identifiable, Equatable {
    public var id: String { sessionId }
    public let sessionId: String
    public let project: String
    public let at: Date
    /// Without the session's cwd unless the host needs it to find the session (`HostAdapter.keepsCwd`).
    public let host: HostInfo?
    /// The repo + worktree label as it was resolved when the thread finished (#111): the cwd itself is not kept.
    public let label: RepoLabel
    /// Whether git had answered for `label`; an unresolved one must not claim an identity slot (#89).
    public let resolved: Bool

    public init(sessionId: String, project: String, at: Date, host: HostInfo? = nil, label: RepoLabel? = nil, resolved: Bool = true) {
        let p = project.isEmpty ? "unknown" : project
        self.sessionId = sessionId; self.project = p; self.at = at; self.host = HostAdapters.minimal(host)
        self.label = label ?? RepoLabel(repo: p); self.resolved = resolved
    }

    /// `label` is the model's resolved label for the finished thread's cwd.
    public init(_ done: DoneItem, label: RepoLabel, resolved: Bool) {
        self.init(sessionId: done.sessionId, project: done.project, at: done.at, host: done.host, label: label, resolved: resolved)
    }
}

/// The last few finished threads, kept in memory only after their chip is dismissed or expires. A hard cap and a TTL
/// bound what lingers. Newest first; one entry per session.
public struct RecentList: Equatable {
    public static let cap = 5
    /// Entries older than this (since they finished) are dropped.
    public static let ttl: TimeInterval = 1800

    public private(set) var items: [RecentItem] = []

    public init() {}

    /// Add a finished thread (replacing an older entry for the same session), keep newest first, cap at `cap`.
    public mutating func add(_ item: RecentItem, now: Date = Date()) {
        items.removeAll { $0.sessionId == item.sessionId }
        items.append(item)
        items = Array(items.enumerated().sorted { ($0.element.at, $0.offset) > ($1.element.at, $1.offset) }.map(\.element).prefix(Self.cap))
        prune(now: now)
    }

    /// Drop expired entries. Returns whether anything changed (callers assign observable state only on change).
    @discardableResult
    public mutating func prune(now: Date = Date()) -> Bool {
        let before = items.count
        items.removeAll { now.timeIntervalSince($0.at) > Self.ttl }
        return items.count != before
    }
}
