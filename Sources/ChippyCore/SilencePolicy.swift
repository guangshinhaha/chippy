import Foundation

/// Injected quiet state (#95). The app layer reads it; this module only decides. Screen recording is deferred
/// (no public detection API).
public struct SilenceState: Equatable {
    public var focus: Bool
    public var locked: Bool
    public init(focus: Bool = false, locked: Bool = false) { self.focus = focus; self.locked = locked }
    public var isQuiet: Bool { focus || locked }
}

/// Quiet means: no sound and no auto-expanding card. It never hides a request: a needs-you still shows on the
/// badge, stays pending and answerable, and the hook's own timeout still hands an approval to the terminal.
public enum SilencePolicy {
    public static func soundsAllowed(_ s: SilenceState) -> Bool { !s.isQuiet }
    /// Whether a new approval/question may open the card by itself. When false it arrives folded onto the badge.
    public static func mayAutoExpand(_ s: SilenceState) -> Bool { !s.isQuiet }
    /// Whether a finished chip may peek open by itself. When false it stays on the collapsed badge.
    public static func mayPeek(_ s: SilenceState) -> Bool { !s.isQuiet }

    public enum FocusReading: Equatable { case on, off, unknown }

    /// Seconds between the Unix epoch and Apple's reference date (2001-01-01), the usual unit of Focus timestamps.
    static let appleEpochOffset: TimeInterval = 978_307_200

    /// Parses ~/Library/DoNotDisturb/DB/Assertions.json. Focus is `.on` only when a record is a dictionary and is active
    /// now: not expired, not starting in the future. An empty `storeAssertionRecords` is `.off`. Anything unexpected
    /// (no data, wrong types, non-dictionary records) is `.unknown`, which callers treat as off (fail open).
    /// Reads key names and timestamps only, never any content. See docs/decisions/focus-detection.md for what was verified.
    public static func readFocus(assertionsJSON data: Data?, now: Date = Date()) -> FocusReading {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [Any] else { return .unknown }
        var sawStore = false
        for entry in list {
            guard let e = entry as? [String: Any], let records = e["storeAssertionRecords"] as? [Any] else { continue }
            sawStore = true
            for r in records {
                guard let rec = r as? [String: Any] else { return .unknown }
                if isActive(rec, now: now) { return .on }
            }
        }
        return (sawStore || list.isEmpty) ? .off : .unknown
    }

    public static func focusIsOn(assertionsJSON data: Data?, now: Date = Date()) -> Bool {
        readFocus(assertionsJSON: data, now: now) == .on
    }

    private static func isActive(_ rec: [String: Any], now: Date) -> Bool {
        let t = now.timeIntervalSince1970
        for (k, v) in rec {
            let key = k.lowercased()
            guard key.contains("expir") || key.contains("start") else { continue }
            guard let n = v as? Double, n > 0 else { continue } // other types: ignored, fail open
            let unix = n < 1_000_000_000 ? n + appleEpochOffset : (n < 4_000_000_000 ? n : n / 1000) // reference-date secs, unix secs, or ms
            if key.contains("expir"), unix <= t { return false }
            if key.contains("start"), unix > t + 1 { return false }
        }
        return true
    }
}

/// Small time-to-live cache so the Focus file is read at most once per `ttl`, and never on the caller's thread when stale:
/// a stale value is returned at once and a refresh runs through `async`. Thread-safe.
public final class FocusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    private var stamp: Date
    private var refreshing = false
    private let ttl: TimeInterval
    private let read: () -> Bool
    private let async: (@escaping () -> Void) -> Void
    private let clock: () -> Date

    public init(ttl: TimeInterval = 2, initial: Bool = false, clock: @escaping () -> Date = Date.init,
                read: @escaping () -> Bool,
                async: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }) {
        self.ttl = ttl; self.clock = clock; self.read = read; self.async = async
        self.value = initial; self.stamp = .distantPast
    }

    public var current: Bool {
        lock.lock()
        let stale = clock().timeIntervalSince(stamp) >= ttl && !refreshing
        if stale { refreshing = true }
        let v = value
        lock.unlock()
        if stale {
            async { [self] in
                let fresh = read()
                lock.lock(); value = fresh; stamp = clock(); refreshing = false; lock.unlock()
            }
        }
        return v
    }
}
