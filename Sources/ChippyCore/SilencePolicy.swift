import Foundation

/// Injected quiet state (#95). The app layer reads it; this module only decides. Screen recording is deferred
/// (no public detection API).
public struct SilenceState: Equatable {
    public var focus: Bool
    public var locked: Bool
    public init(focus: Bool = false, locked: Bool = false) { self.focus = focus; self.locked = locked }
    public var isQuiet: Bool { focus || locked }
}

/// Quiet (`SilenceState.isQuiet`) means: no sound, no auto-expanding card, no peek. It never hides a request: a needs-you still shows on the
/// badge, stays pending and answerable, and the hook's own timeout still hands an approval to the terminal.
public enum SilencePolicy {
    public enum FocusReading: Equatable { case on, off, unknown }

    /// Seconds between the Unix epoch and Apple's reference date (2001-01-01), the usual unit of Focus timestamps.
    static let appleEpochOffset: TimeInterval = 978_307_200

    /// Parses ~/Library/DoNotDisturb/DB/Assertions.json. Focus is `.on` only when a record is a dictionary with a recognised
    /// start or expiry timestamp and is active now (not expired, not starting in the future). An empty `storeAssertionRecords`
    /// is `.off`. A record with no recognised timestamp, or anything unexpected (no data, wrong types, non-dictionary
    /// records), is `.unknown`, which callers treat as off (fail open). Reads key names and timestamps only, never any
    /// content. See docs/decisions/focus-detection.md for what was verified.
    public static func readFocus(assertionsJSON data: Data?, now: Date = Date()) -> FocusReading {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [Any] else { return .unknown }
        var sawStore = false, sawUnknown = false
        for entry in list {
            guard let e = entry as? [String: Any], let records = e["storeAssertionRecords"] as? [Any] else { continue }
            sawStore = true
            for r in records {
                guard let rec = r as? [String: Any] else { sawUnknown = true; continue }
                switch recordState(rec, now: now) {
                case .active: return .on
                case .inactive: break
                case .unrecognised: sawUnknown = true
                }
            }
        }
        if sawUnknown { return .unknown }
        return (sawStore || list.isEmpty) ? .off : .unknown
    }

    public static func focusIsOn(assertionsJSON data: Data?, now: Date = Date()) -> Bool {
        readFocus(assertionsJSON: data, now: now) == .on
    }

    private enum RecordState { case active, inactive, unrecognised }

    private static func recordState(_ rec: [String: Any], now: Date) -> RecordState {
        let t = now.timeIntervalSince1970
        var recognised = false, active = true
        for (k, v) in rec {
            let key = k.lowercased()
            guard key.contains("expir") || key.contains("start") else { continue }
            // NSNumber booleans bridge to Double (true is 1.0): never a timestamp. Other types: ignored.
            guard let num = v as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() else { continue }
            let n = num.doubleValue
            guard n > 0 else { continue }
            recognised = true
            let unix = n < 1_000_000_000 ? n + appleEpochOffset : (n < 4_000_000_000 ? n : n / 1000) // reference-date secs, unix secs, or ms
            if key.contains("expir"), unix <= t { active = false }
            if key.contains("start"), unix > t + 1 { active = false }
        }
        return recognised ? (active ? .active : .inactive) : .unrecognised
    }

    /// Whether the login session is locked or not on the console (fast user switch), from the dictionary returned by
    /// `CGSessionCopyCurrentDictionary()`. Read live, so a missed distributed unlock notification cannot leave Chippy quiet.
    /// A missing dictionary reads as not locked (fail open).
    public static func sessionIsLocked(_ dict: [String: Any]?) -> Bool {
        guard let dict else { return false }
        if let l = dict["CGSSessionScreenIsLocked"] as? Bool, l { return true }
        if let c = dict["kCGSSessionOnConsoleKey"] as? Bool, !c { return true }
        return false
    }
}

/// Small time-to-live cache so the Focus file is read at most once per `ttl`. `current` never returns a value older
/// than `ttl`: when stale it reads synchronously (the file is tiny) and caches the result. A background refresh starts
/// once the value is half-aged, only so the synchronous read is rarely needed. Thread-safe.
public final class FocusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: SilencePolicy.FocusReading = .unknown
    private var stamp: Date = .distantPast
    private var refreshing = false
    private var generation = 0
    private let ttl: TimeInterval
    private let read: () -> SilencePolicy.FocusReading
    private let async: (@escaping () -> Void) -> Void
    private let clock: () -> Date

    public init(ttl: TimeInterval = 2, clock: @escaping () -> Date = Date.init,
                read: @escaping () -> SilencePolicy.FocusReading,
                async: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }) {
        self.ttl = ttl; self.clock = clock; self.read = read; self.async = async
    }

    /// Stores only if no `invalidate()` happened since `gen` was taken, so a late refresh cannot overwrite a newer value.
    private func store(_ r: SilencePolicy.FocusReading, gen: Int) {
        lock.lock(); defer { lock.unlock() }
        guard gen == generation else { return }
        reading = r; stamp = clock(); refreshing = false
    }

    private var snapshot: SilencePolicy.FocusReading {
        lock.lock()
        let age = clock().timeIntervalSince(stamp)
        let r = reading
        let prefetch = age >= ttl / 2 && age < ttl && !refreshing
        if prefetch { refreshing = true }
        let gen = generation
        lock.unlock()
        if age >= ttl { let fresh = read(); store(fresh, gen: gen); return fresh }
        if prefetch { async { [self] in store(read(), gen: gen) } }
        return r
    }

    /// Forget the cached reading (wake, session active): the next read is synchronous.
    public func invalidate() { lock.lock(); stamp = .distantPast; generation += 1; refreshing = false; lock.unlock() }

    /// Focus is on. Unknown counts as off (fail open).
    public var current: Bool { snapshot == .on }
    /// The last read could not be understood (typically no Full Disk Access). Reads if stale.
    public var unreadable: Bool { snapshot == .unknown }
}
