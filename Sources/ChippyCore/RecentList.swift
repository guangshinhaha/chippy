import Foundation

/// One entry of the Recent list (#85). By construction it holds no reply, prompt, question or command (PDPA #30):
/// only the repo name, when the thread finished, and which app hosts it (for the Open button).
public struct RecentItem: Identifiable, Equatable {
    public var id: String { sessionId }
    public let sessionId: String
    public let project: String
    public let at: Date
    public let host: HostInfo?
    /// Kept only to resolve the repo + worktree label (#101); never shown.
    public let cwd: String

    public init(sessionId: String, project: String, at: Date, host: HostInfo? = nil, cwd: String = "") {
        self.sessionId = sessionId; self.project = project.isEmpty ? "unknown" : project; self.at = at; self.host = host; self.cwd = cwd
    }

    public init(_ done: DoneItem) { self.init(sessionId: done.sessionId, project: done.project, at: done.at, host: done.host, cwd: done.cwd) }
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
