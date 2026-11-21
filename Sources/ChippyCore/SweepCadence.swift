import Foundation

/// How often the app calls `NotchModel.sweep` (#180). Sweep is what notices the things no event announces: a hook that hung up,
/// a request whose wait ran out, a fold or peek that came due, a chip that aged out, quiet ending, the away poll, sleep.
/// Anything the user can see counting down needs `fast`; with nothing on screen `slow` is enough, so an idle Chippy wakes
/// 12 times a minute, not 120. Pure; the model fills `Inputs` and the app owns the timer.
///
/// When in doubt, an input must make the answer `fast`: a wrong `slow` silently breaks expiry, while a wrong `fast` only costs wakeups.
public enum SweepCadence {
    public static let fast: TimeInterval = 0.5
    public static let slow: TimeInterval = 5

    /// Everything that can make a sweep matter within a second. Every field is required (no defaults), so adding a new
    /// time-based piece of state forces each call site, and its test, to say how it feeds the cadence.
    public struct Inputs: Equatable {
        /// An approval or question is waiting: hang-up and wait-over detection, the fold timer, quiet re-evaluation, countdowns.
        public var hasPending: Bool
        /// A finished or asked-in-terminal chip is showing: it expires after `doneSeconds` / `terminalSeconds`.
        public var hasChips: Bool
        /// A finished chip is peeking (including paused by hover): it settles to collapsed when the peek ends.
        public var peeking: Bool
        /// Approvals are folded into the badge (their deadline ring drains on screen).
        public var folded: Bool
        /// Requests held folded only because of quiet (Focus / locked): sweep notices quiet ending.
        public var quietFolded: Bool
        /// The rest panel, waiting list or done detail is open: the user is looking, so lists and ages stay current.
        public var panelOpen: Bool

        public init(hasPending: Bool, hasChips: Bool, peeking: Bool, folded: Bool, quietFolded: Bool, panelOpen: Bool) {
            self.hasPending = hasPending; self.hasChips = hasChips; self.peeking = peeking
            self.folded = folded; self.quietFolded = quietFolded; self.panelOpen = panelOpen
        }
    }

    /// 0.5s while anything time-based is on screen or waiting, 5s otherwise.
    public static func interval(_ i: Inputs) -> TimeInterval {
        i.hasPending || i.hasChips || i.peeking || i.folded || i.quietFolded || i.panelOpen ? fast : slow
    }

    public static func interval(hasPending: Bool, hasChips: Bool, peeking: Bool, folded: Bool, quietFolded: Bool, panelOpen: Bool) -> TimeInterval {
        interval(Inputs(hasPending: hasPending, hasChips: hasChips, peeking: peeking, folded: folded, quietFolded: quietFolded, panelOpen: panelOpen))
    }

    /// Timer tolerance: 20% of the interval, so the system can coalesce the wakeup with others (never below the 10% the issue asks).
    public static func tolerance(for interval: TimeInterval) -> TimeInterval { interval * 0.2 }
}

/// Remembers which interval the sweep timer is scheduled at, so the timer is replaced only when the answer changes.
/// The timer is one-shot and rescheduled after every sweep: consecutive sweeps are then at least one interval apart,
/// which the model's 5s away poll relies on (a repeating timer with tolerance can fire two ticks less than 5s apart).
public struct SweepPacer: Equatable {
    public private(set) var scheduled: TimeInterval?

    public init() {}

    /// Whether the timer must be (re)scheduled for `wanted`: nothing is scheduled (first run, or it just fired), or the answer changed.
    public func needsSchedule(for wanted: TimeInterval) -> Bool { scheduled != wanted }

    public mutating func didSchedule(_ interval: TimeInterval) { scheduled = interval }

    /// The one-shot timer fired: nothing is scheduled until the next `didSchedule`.
    public mutating func didFire() { scheduled = nil }
}
