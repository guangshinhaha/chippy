import Foundation

public enum Channel: String, Codable {
    case notch      // answered from the notch (click, or an earlier "Always" answering for you)
    case terminal   // the hook gave up or the terminal answered first
}

/// One idle-wait event. Deliberately no command text or file paths: project name and tool only.
public struct WaitEvent: Codable, Equatable {
    public let ts: String
    public let waitMs: Int
    public let channel: Channel
    public let decision: String   // allow | deny | always | auto_always | none
    public let project: String
    public let tool: String

    enum CodingKeys: String, CodingKey { case ts, waitMs = "wait_ms", channel, decision, project, tool }
}

/// Append-only JSON Lines at ~/Library/Application Support/Chippy/events.jsonl. No server, no database.
public final class EventLog {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL = ChippyPaths.supportDir.appendingPathComponent("events.jsonl")) { self.url = url }

    public func append(_ r: PendingRequest, channel: Channel, decision: String, now: Date = Date()) {
        let e = WaitEvent(ts: ISO8601DateFormatter().string(from: now),
                          waitMs: max(0, Int(now.timeIntervalSince(r.createdAt) * 1000)),
                          channel: channel, decision: decision, project: r.project, tool: r.toolName)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? enc.encode(e) else { return }
        line.append(10)
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    public static func read(_ url: URL) -> [WaitEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        // Split bytes, not a String: one bad byte must not drop the whole log.
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? dec.decode(WaitEvent.self, from: Data($0)) }
    }
}

/// The two PRD §7 measures, computed straight from the log.
public struct WaitSummary: Equatable {
    public let total: Int
    public let totalWaitMs: Int
    public let medianWaitMs: Int
    public let fromNotch: Int
    public let fromTerminal: Int
    /// Share of approvals actioned from the notch rather than the terminal (0...1).
    public var notchShare: Double { total == 0 ? 0 : Double(fromNotch) / Double(total) }

    public init(_ events: [WaitEvent]) {
        total = events.count
        totalWaitMs = events.reduce(0) { $0 + $1.waitMs }
        let w = events.map(\.waitMs).sorted()
        medianWaitMs = w.isEmpty ? 0 : (w.count % 2 == 1 ? w[w.count / 2] : (w[w.count / 2 - 1] + w[w.count / 2]) / 2)
        fromNotch = events.filter { $0.channel == .notch }.count
        fromTerminal = events.filter { $0.channel == .terminal }.count
    }

    /// Parse `ts` once per event; events with an unparseable `ts` are left out.
    public static func dated(_ events: [WaitEvent]) -> [(date: Date, event: WaitEvent)] {
        let f = ISO8601DateFormatter()
        return events.compactMap { e in f.date(from: e.ts).map { ($0, e) } }
    }

    /// Events at or after `since`, from `dated(_:)`.
    public init(dated: [(date: Date, event: WaitEvent)], since: Date) {
        self.init(dated.filter { $0.date >= since }.map(\.event))
    }

    /// Events at or after `since` (by `ts`; an unparseable `ts` is left out).
    public init(_ events: [WaitEvent], since: Date) {
        let f = ISO8601DateFormatter()
        self.init(events.filter { e in f.date(from: e.ts).map { $0 >= since } ?? false })
    }

    /// "3m 20s", "45s", "41m", "1h 5m": whole seconds under an hour, whole minutes beyond.
    public static func duration(ms: Int) -> String {
        let s = max(0, ms / 1000)
        if s < 60 { return "\(s)s" }
        if s < 3600 { let m = s / 60, r = s % 60; return r == 0 ? "\(m)m" : "\(m)m \(r)s" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// One menu line, e.g. "Waited on you today: 3m 20s · 62% from notch". `showAsks` appends "(27 asks)".
    public func menuLine(label: String, showAsks: Bool = false) -> String {
        guard total > 0 else { return "\(label): none yet" }
        let asks = showAsks ? " (\(total) \(total == 1 ? "ask" : "asks"))" : ""
        return "\(label): \(Self.duration(ms: totalWaitMs)) · \(Int((notchShare * 100).rounded()))% from notch\(asks)"
    }
}
