import Foundation

/// Approvals and questions open the notch with no click (#86), then fold after `duration` seconds into a pulsing
/// "needs you" badge. The request stays pending; only the card goes away. The timer is a `PeekGate` (hover pauses
/// it, a new request restarts it, a hover that is already resting on the island starts it paused). A card the user
/// opened themselves is pinned and never folds. Pure; the clock is injected like `PeekGate`'s.
public struct NeedsMeFold: Equatable {
    public static let duration: TimeInterval = 15

    private var gate: PeekGate
    private var armed = false
    private var pinned = false

    public init(duration: TimeInterval = NeedsMeFold.duration) { gate = PeekGate(duration: duration) }

    /// A new approval or question arrived: restart the full timer (and unfold). `engaged` means the user already
    /// had a panel open by their own click (rest panel, list, done detail), or has a card pinned: no timer then.
    public mutating func arrive(now: TimeInterval, hovering: Bool, engaged: Bool) {
        if engaged || pinned { pin(); return }
        armed = true
        gate.start(now: now, hovering: hovering)
    }

    /// The user opened the card (click, list jump, key): it stays until nothing is pending.
    public mutating func pin() { pinned = true; armed = false; gate.cancel() }

    public mutating func setHover(_ inside: Bool, now: TimeInterval) { gate.setHover(inside, now: now) }

    /// Nothing is pending any more: forget the timer and the pin.
    public mutating func reset() { armed = false; pinned = false; gate.cancel() }

    public var isPinned: Bool { pinned }

    /// True once an armed, unpinned timer has run out.
    public func isDue(now: TimeInterval) -> Bool { armed && !pinned && !gate.isPeeking(now: now) }

    /// Seconds a request still has before the hook gives up and the terminal takes over (never negative).
    /// A fold at 15s of a 20s approval leaves 5s, and the badge must keep saying so.
    public static func timeLeft(createdAt: Date, timeout: TimeInterval, now: Date) -> TimeInterval {
        max(0, timeout - now.timeIntervalSince(createdAt))
    }

    /// 1 at arrival down to 0 at the timeout, for a draining ring.
    public static func fractionLeft(createdAt: Date, timeout: TimeInterval, now: Date) -> Double {
        guard timeout > 0 else { return 0 }
        return min(1, timeLeft(createdAt: createdAt, timeout: timeout, now: now) / timeout)
    }
}
