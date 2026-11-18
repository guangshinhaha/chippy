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
    /// Sleep only when nothing is asking for attention: a running tool with no events for a while, or a
    /// pending approval, must not look asleep.
    public static func shouldSleep(state: ChippyState, clock: IdleClock, now: Date = Date()) -> Bool {
        switch state {
        case .working, .needsYou: return false
        case .idle, .done: return clock.isAsleep(now: now)
        }
    }
}
