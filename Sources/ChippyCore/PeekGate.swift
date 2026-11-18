import Foundation

/// The "peek" of a finished chip: the island shows compact for `duration` seconds, then settles to collapsed.
/// The countdown pauses while the cursor is over the island and restarts in full when it leaves; a new message
/// restarts it. Pure; the clock is injected (seconds on any monotonic scale), like `GapGate`.
/// Approvals and questions are not handled here: the model keeps them expanded regardless of the peek.
public struct PeekGate: Equatable {
    public var duration: TimeInterval
    private var deadline: TimeInterval?
    private var active = false
    private var hovering = false

    public init(duration: TimeInterval = 10) { self.duration = duration }

    /// A finished chip (or any new message) arrived: peek for a full `duration` (held open while hovered).
    public mutating func start(now: TimeInterval) {
        active = true
        deadline = hovering ? nil : now + duration
    }

    /// The cursor entered or left the island. Entering pauses; leaving restarts the full countdown.
    public mutating func setHover(_ inside: Bool, now: TimeInterval) {
        guard inside != hovering else { return }
        hovering = inside
        guard active else { return }
        deadline = inside ? nil : now + duration
    }

    /// Peeking up to, but not including, the deadline: at exactly `duration` seconds the peek is over.
    public func isPeeking(now: TimeInterval) -> Bool {
        guard active else { return false }
        guard let d = deadline else { return true } // paused by hover
        return now < d
    }

    /// Nothing is waiting any more: forget the peek.
    public mutating func cancel() { active = false; deadline = nil }

    /// Count badge on the collapsed notch: nothing at 0, one digit up to 9, then "9+".
    public static func badge(count: Int) -> String? {
        count <= 0 ? nil : (count > 9 ? "9+" : String(count))
    }
}
