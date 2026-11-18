import Darwin
import Foundation

/// The "peek" of a finished chip: the island shows compact for `duration` seconds, then settles to collapsed.
/// Hovering the island pauses a running peek; leaving resumes it with the time that was left. A new message
/// restarts it in full. Pure; the clock is injected (seconds on any monotonic scale), like `GapGate`.
/// Approvals and questions are not handled here: the model keeps them expanded regardless of the peek.
public struct PeekGate: Equatable {
    public var duration: TimeInterval
    private var active = false
    private var deadline: TimeInterval?   // running: when it ends
    private var remaining: TimeInterval?  // paused by hover: what was left

    public init(duration: TimeInterval = 10) { self.duration = duration }

    /// Monotonic seconds that keep counting while the Mac sleeps (CLOCK_MONOTONIC; `systemUptime` does not),
    /// so a peek never outlives a sleep.
    public static func monotonicNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// A finished chip (or any new message) arrived: a full `duration`, always running. A hover that began
    /// earlier does not hold it; only a fresh hover pauses it.
    public mutating func start(now: TimeInterval) {
        active = true
        deadline = now + duration
        remaining = nil
    }

    /// The cursor is over / off the island. Only a peek that is running (or paused) is affected: hovering an
    /// expired or collapsed notch never re-opens it. Idempotent.
    public mutating func setHover(_ inside: Bool, now: TimeInterval) {
        guard active else { return }
        if inside, let d = deadline {
            guard now < d else { return }        // already expired
            remaining = d - now; deadline = nil
        } else if !inside, let r = remaining {
            deadline = now + r; remaining = nil
        }
    }

    /// Peeking up to, but not including, the deadline: at exactly `duration` seconds the peek is over.
    public func isPeeking(now: TimeInterval) -> Bool {
        guard active else { return false }
        guard let d = deadline else { return true } // paused by hover
        return now < d
    }

    /// Nothing is waiting any more, or the user took over: forget the peek.
    public mutating func cancel() { active = false; deadline = nil; remaining = nil }

    /// Count badge on the collapsed notch: nothing at 0, one digit up to 9, then "9+".
    public static func badge(count: Int) -> String? {
        count <= 0 ? nil : (count > 9 ? "9+" : String(count))
    }
}
