import CryptoKit
import Foundation

/// One line of the activity log (#168): when, what kind, and which repo or worktree. Nothing else.
/// `sid` is a salted hash of the session id, only so one session stays one row: the id itself, a transcript path,
/// a prompt, reply, question, command or file path never reach this type (PDPA #30).
public struct ActivityEvent: Codable, Equatable {
    public enum Status: String, Codable { case needsYou, asksYou, finished }
    public let ts: String
    public let status: Status
    public let repo: String
    public let worktree: String?
    public let sid: String

    public var date: Date? { ISO8601DateFormatter().date(from: ts) }
}

/// Append-only JSON Lines at ~/Library/Application Support/Chippy/activity.jsonl (0600, like events.jsonl). It lets the
/// away digest survive a restart. Nothing leaves the machine. Capped: `trim` runs at launch.
public final class ActivityLog {
    public static let maxAge: TimeInterval = 14 * 86_400
    public static let maxLines = 2000

    public let url: URL
    private let lock = NSLock()
    private var lastWindow: Window??

    public init(url: URL = ChippyPaths.supportDir.appendingPathComponent("activity.jsonl")) { self.url = url }

    /// The log as the app runs it: trimmed once, here.
    public static func launch() -> ActivityLog {
        let log = ActivityLog()
        log.trim()
        return log
    }

    private var saltURL: URL { URL(fileURLWithPath: url.path + ".salt") }
    private var windowURL: URL { URL(fileURLWithPath: url.path + ".window") }

    // MARK: session key

    private lazy var salt: Data = {
        if let d = try? Data(contentsOf: saltURL), d.count == 16 { return d }
        let d = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        Self.save(d, to: saltURL)
        return d
    }()

    /// Stable for one install, useless anywhere else: the first 8 bytes of SHA-256(salt + id).
    public func hash(_ sessionId: String) -> String {
        lock.lock(); let s = salt; lock.unlock()
        return SHA256.hash(data: s + Data(sessionId.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: events

    public func record(_ status: ActivityEvent.Status, sessionId: String, label: RepoLabel, at: Date) {
        let e = ActivityEvent(ts: ISO8601DateFormatter().string(from: at), status: status, repo: label.repo, worktree: label.worktree, sid: hash(sessionId))
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? enc.encode(e) else { return }
        line.append(10)
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    public func events() -> [ActivityEvent] {
        lock.lock(); defer { lock.unlock() }
        return Self.read(url)
    }

    static func read(_ url: URL) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        // Split bytes, not a String: one bad byte must not drop the whole log.
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? dec.decode(ActivityEvent.self, from: Data($0)) }
    }

    /// Drop lines older than `maxAge` (and any that don't parse), then keep only the newest `maxLines`. Rewrites the file only when
    /// something goes, through a temp file and a rename, so a crash mid-trim leaves the old log whole.
    public func trim(now: Date = Date(), maxAge: TimeInterval = ActivityLog.maxAge, maxLines: Int = ActivityLog.maxLines) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let dec = JSONDecoder()
        let cutoff = now.addingTimeInterval(-maxAge)
        let keep = lines.filter { l in
            guard let e = try? dec.decode(ActivityEvent.self, from: Data(l)), let d = e.date else { return false }
            return d >= cutoff
        }.suffix(max(0, maxLines))
        guard keep.count != lines.count else { return }
        var out = Data()
        for l in keep { out.append(Data(l)); out.append(10) }
        Self.saveAtomically(out, to: url)
    }

    // MARK: the away window (two dates), so a restart still knows which period the digest covers

    struct Window: Codable, Equatable { let since: Double; let end: Double? }

    public func saveWindow(since: Date?, end: Date?) {
        let w = since.map { Window(since: $0.timeIntervalSince1970, end: end?.timeIntervalSince1970) }
        lock.lock(); defer { lock.unlock() }
        if let last = lastWindow, last == w { return }
        lastWindow = .some(w)
        if let w, let data = try? JSONEncoder().encode(w) { Self.saveAtomically(data, to: windowURL) }
        else { try? FileManager.default.removeItem(at: windowURL) }
    }

    public func loadWindow() -> (since: Date, end: Date?)? {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: windowURL), let w = try? JSONDecoder().decode(Window.self, from: d) else { return nil }
        return (Date(timeIntervalSince1970: w.since), w.end.map { Date(timeIntervalSince1970: $0) })
    }

    /// Temp file (0600) then a rename: a crash mid-write leaves the old file whole.
    private static func saveAtomically(_ data: Data, to url: URL) {
        let tmp = URL(fileURLWithPath: url.path + ".tmp")
        save(data, to: tmp)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private static func save(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
