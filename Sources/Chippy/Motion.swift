import SwiftUI

/// Every animation timing in the app, named by purpose (#207). Values are the ones the views used before
/// they were collected here; tune them here, not at the call sites.
enum Motion {
    /// Button and panel press feedback.
    static let press = Animation.easeOut(duration: 0.12)
    /// Hover and selection highlights (colour only).
    static let hover = Animation.easeOut(duration: 0.12)
    /// Incoming content (`Reveal`); callers add their own `.delay`. A strong ease-out (#214): fast start, soft settle.
    static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    /// Outgoing content fade.
    static let exit = Animation.easeOut(duration: 0.1)
    /// PlanCard "Show more" / "Show less".
    static let expand = Animation.easeOut(duration: 0.18)
    /// The notch shape: one spring, slight settle, no bounce.
    static let shape = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Near-instant change for Reduce Motion, and to end a repeating animation.
    static let instant = Animation.linear(duration: 0.01)
    /// Near-instant Reduce Motion fade where the full fade is ease-out (kept apart from `instant` so no curve changes).
    static let instantEase = Animation.easeOut(duration: 0.01)
    /// The needs-you badge pulse (#86). Started only while needed and never under Reduce Motion.
    static let pulse = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

    /// `a`, or `instant` when the user asked for reduced motion.
    static func or(_ a: Animation, reduce: Bool) -> Animation { reduce ? instant : a }
}
