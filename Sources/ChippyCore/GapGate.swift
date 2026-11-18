import CoreGraphics
import Foundation

/// Decides when a measured menu bar gap may reach the shape: a change must hold for `stability` seconds, and is
/// applied only when no card is expanded and the last density change has settled. A skipped application stays
/// pending (re-read on every call), so it lands once the gate opens, whatever the readings do in between.
/// Pure; the clock is injected. Times are seconds on any monotonic scale.
public struct GapGate {
    public typealias Gap = (CGFloat, CGFloat)
    public var stability: TimeInterval = 0.4
    public var settle: TimeInterval = 0.8
    public private(set) var applied: Gap
    private var pending: Gap?
    private var pendingSince: TimeInterval = 0
    private var expanded = false
    private var lastDensityChange: TimeInterval = -.infinity

    public init(applied: Gap = (.infinity, .infinity)) { self.applied = applied }

    public var hasPending: Bool { pending != nil }

    /// A fresh reading. Returns a gap to apply now, if the gate is open.
    @discardableResult
    public mutating func observe(_ g: Gap, now: TimeInterval) -> Gap? {
        if MenuBarGap.same(g, applied) { pending = nil }
        else if pending == nil || !MenuBarGap.same(g, pending!) { pending = g; pendingSince = now }
        return poll(now: now)
    }

    /// Density changed. A stable pending gap rides along with this (already animating) change.
    @discardableResult
    public mutating func densityChanged(expanded: Bool, now: TimeInterval) -> Gap? {
        self.expanded = expanded
        lastDensityChange = now
        guard !expanded, let p = pending, now - pendingSince >= stability else { return nil }
        applied = p; pending = nil
        return p
    }

    /// Re-evaluate without a new reading (call after `stability` / `settle` have elapsed).
    @discardableResult
    public mutating func poll(now: TimeInterval) -> Gap? {
        guard let p = pending, !expanded, now - pendingSince >= stability, now - lastDensityChange >= settle else { return nil }
        applied = p; pending = nil
        return p
    }
}

extension MenuBarGap {
    /// Keeps only frames that can be menu bar items on this screen: inside its bounds, no taller than the bar,
    /// narrower than ~400pt (drops full-width bars, overlays and other displays' windows).
    public static func plausible(_ frames: [CGRect], screen: CGRect, menuBarHeight: CGFloat) -> [CGRect] {
        frames.filter { !$0.isEmpty && screen.contains(CGPoint(x: $0.midX, y: $0.midY)) && $0.height <= menuBarHeight && $0.width < 400 }
    }
}
