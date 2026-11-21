import Foundation

/// Pure idle-sleep policy (#54, #72): the mascot falls asleep after `after` seconds with no hook events and
/// wakes on any event. No timers here; the caller asks with an injectable `now`.
public struct IdleClock: Equatable {
    public static let sleepAfter: TimeInterval = 300

    public private(set) var lastEvent: Date
    public let after: TimeInterval

    public init(now: Date = Date(), after: TimeInterval = IdleClock.sleepAfter) {
        self.lastEvent = now
        self.after = after
    }

    /// Any hook event (including an approval request) wakes the mascot and restarts the countdown.
    public mutating func noteEvent(now: Date = Date()) { lastEvent = now }

    public func isAsleep(now: Date = Date()) -> Bool { now.timeIntervalSince(lastEvent) >= after }
}

public enum SleepPolicy {
    /// Sleep only when truly idle: a running tool, a pending approval, or a finished chip (its badge) must
    /// never be hidden behind a sleeping pose.
    /// A quiet session whose row is `.done` but whose chip is gone counts as idle.
    public static func shouldSleep(state: ChippyState, hasDoneChips: Bool, clock: IdleClock, now: Date = Date()) -> Bool {
        let quiet = state == .idle || (state == .done && !hasDoneChips)
        return quiet && clock.isAsleep(now: now)
    }
}

/// Whether the sleeping mascot should animate (#181). The breath is cosmetic, so it never runs when nobody can see it
/// (screen locked), when Reduce Motion is on, or for long: 10 minutes covers glancing at a just-idle mascot, and every
/// redraw after that is a wakeup spent on a pose nobody is watching (overnight, lunch). Otherwise the static closed-eyes pose.
public enum SleepAnimation {
    public static let maxAsleep: TimeInterval = 600
    /// 2 fps is plenty for a 4 s breath.
    public static let frameInterval: TimeInterval = 0.5

    public static func shouldAnimate(asleep: Bool, reduceMotion: Bool, screenLocked: Bool, asleepFor: TimeInterval,
                                     maxAsleep: TimeInterval = SleepAnimation.maxAsleep) -> Bool {
        asleep && !reduceMotion && !screenLocked && asleepFor < maxAsleep
    }

    /// When the animation stops for good, given when sleep began.
    public static func end(asleepSince: Date) -> Date { asleepSince.addingTimeInterval(maxAsleep) }
}
