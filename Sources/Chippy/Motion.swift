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
    /// PlanCard "Show more" / "Show less". The same strong ease-out as `enter`, kept short.
    static let expand = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    /// The notch shape: one spring, slight settle, no bounce.
    static let shape = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Near-instant change for Reduce Motion, and to end a repeating animation.
    static let instant = Animation.linear(duration: 0.01)
    /// Reduce Motion keeps opacity and colour fades, gentler rather than zero (C22); only movement and scale go instant.
    static let reducedFade = Animation.easeOut(duration: 0.12)
    /// The needs-you badge pulse (#86). Started only while needed and never under Reduce Motion.
    static let pulse = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

    /// `a`, or `instant` when the user asked for reduced motion. For movement and scale.
    static func or(_ a: Animation, reduce: Bool) -> Animation { reduce ? instant : a }

    /// `a`, or the short `reducedFade` when the user asked for reduced motion. For opacity and colour only.
    static func fade(_ a: Animation, reduce: Bool) -> Animation { reduce ? reducedFade : a }
}
