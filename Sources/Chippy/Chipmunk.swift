import ChippyCore
import Combine
import SwiftUI

/// Chippy, static (no animation, no sound: v1.1). Original geometric design drawn from scratch in a
/// 100x100 space: round head, forehead stripes, cream cheek pouches. One look per v1 state.
struct ChipmunkView: View {
    let state: ChippyState
    /// Idle for 5 minutes (#54): closed eyes, slow breathing and drifting z's. Static under Reduce Motion.
    var sleeping = false
    /// When sleep began (#181); the breath stops `SleepAnimation.maxAsleep` later. Nil = unknown, treated as just now.
    var asleepSince: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Screen lock, kept current by the lock/unlock distributed notifications (no polling, no timer).
    @State private var locked = false

    private let fur = Color(red: 0.74, green: 0.46, blue: 0.22)
    private let dark = Color(red: 0.30, green: 0.17, blue: 0.09)
    private let cream = Color(red: 0.98, green: 0.90, blue: 0.74)
    private let pink = Color(red: 0.93, green: 0.62, blue: 0.58)

    var body: some View {
        Group {
            if sleeping && !reduceMotion && !locked {
                // Ticks stop at `end` (and the last tick draws the static pose), so a long sleep costs no wakeups.
                let since = asleepSince ?? Date()
                TimelineView(CountdownSchedule(end: SleepAnimation.end(asleepSince: since), step: SleepAnimation.frameInterval)) { tl in
                    canvas(t: animates(at: tl.date, since: since) ? tl.date.timeIntervalSinceReferenceDate : nil)
                }
            } else {
                canvas(t: nil)
            }
        }
        .onAppear { locked = SoundPlayer.screenIsLocked() }
        .onChange(of: sleeping) { now in if now { locked = SoundPlayer.screenIsLocked() } } // heal a missed notification
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))) { _ in locked = true }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsUnlocked"))) { _ in locked = false }
    }

    private func animates(at date: Date, since: Date) -> Bool {
        SleepAnimation.shouldAnimate(asleep: sleeping, reduceMotion: reduceMotion, screenLocked: locked, asleepFor: date.timeIntervalSince(since))
    }

    /// `t` nil = static pose (no animation).
    private func canvas(t: Double?) -> some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100
            ctx.translateBy(x: (size.width - 100 * s) / 2, y: (size.height - 100 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            let outer = ctx // unscaled pass for the z's, unaffected by the breath
            if sleeping, let t { // slow breath: 4 s period, +-2.5% about the chin
                let k = 1 + 0.025 * sin(t * 2 * .pi / 4)
                ctx.translateBy(x: 50, y: 92); ctx.scaleBy(x: k, y: k); ctx.translateBy(x: -50, y: -92)
            }
            func oval(_ r: CGRect, _ c: Color) { ctx.fill(Path(ellipseIn: r), with: .color(c)) }
            func stroke(_ p: Path, _ c: Color, _ w: CGFloat) {
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
            func line(_ a: CGPoint, _ b: CGPoint, _ c: Color, _ w: CGFloat) {
                var p = Path(); p.move(to: a); p.addLine(to: b); stroke(p, c, w)
            }
            func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, up: Bool, _ w: CGFloat = 3.5) {
                var p = Path()
                p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(up ? 200 : 20),
                         endAngle: .degrees(up ? 340 : 160), clockwise: false)
                stroke(p, dark, w)
            }

            // ears, head, stripes, cheeks
            oval(CGRect(x: 14, y: 14, width: 24, height: 24), fur); oval(CGRect(x: 20, y: 20, width: 12, height: 12), pink)
            oval(CGRect(x: 62, y: 14, width: 24, height: 24), fur); oval(CGRect(x: 68, y: 20, width: 12, height: 12), pink)
            oval(CGRect(x: 8, y: 20, width: 84, height: 72), fur)
            line(CGPoint(x: 50, y: 21), CGPoint(x: 50, y: 40), dark, 5)
            line(CGPoint(x: 41, y: 22), CGPoint(x: 39, y: 39), cream, 4); line(CGPoint(x: 59, y: 22), CGPoint(x: 61, y: 39), cream, 4)
            line(CGPoint(x: 32, y: 25), CGPoint(x: 30, y: 38), dark, 4); line(CGPoint(x: 68, y: 25), CGPoint(x: 70, y: 38), dark, 4)
            oval(CGRect(x: 12, y: 56, width: 40, height: 32), cream); oval(CGRect(x: 48, y: 56, width: 40, height: 32), cream)
            oval(CGRect(x: 45, y: 58, width: 10, height: 7), dark)

            // eyes + mouth per state
            let leftEye = CGPoint(x: 34, y: 52), rightEye = CGPoint(x: 66, y: 52)
            switch sleeping ? ChippyState.idle : state {
            case .idle: // asleep
                arc(leftEye.x, leftEye.y - 3, 6, up: false); arc(rightEye.x, rightEye.y - 3, 6, up: false)
                line(CGPoint(x: 46, y: 72), CGPoint(x: 54, y: 72), dark, 3)
            case .working: // focused: eyes open, brows down, small smirk
                oval(CGRect(x: leftEye.x - 5, y: leftEye.y - 5, width: 10, height: 11), dark)
                oval(CGRect(x: rightEye.x - 5, y: rightEye.y - 5, width: 10, height: 11), dark)
                line(CGPoint(x: 27, y: 43), CGPoint(x: 40, y: 46), dark, 3); line(CGPoint(x: 73, y: 43), CGPoint(x: 60, y: 46), dark, 3)
                arc(52, 66, 7, up: false, 3)
            case .needsYou: // alarmed: big eyes, brows up, open mouth
                oval(CGRect(x: leftEye.x - 7, y: leftEye.y - 8, width: 14, height: 17), .white)
                oval(CGRect(x: rightEye.x - 7, y: rightEye.y - 8, width: 14, height: 17), .white)
                oval(CGRect(x: leftEye.x - 3, y: leftEye.y - 3, width: 7, height: 9), dark)
                oval(CGRect(x: rightEye.x - 3, y: rightEye.y - 3, width: 7, height: 9), dark)
                line(CGPoint(x: 26, y: 38), CGPoint(x: 40, y: 36), dark, 3); line(CGPoint(x: 74, y: 38), CGPoint(x: 60, y: 36), dark, 3)
                oval(CGRect(x: 45, y: 68, width: 10, height: 12), dark)
            case .done: // content: happy closed eyes, wide smile
                arc(leftEye.x, leftEye.y + 3, 6, up: true); arc(rightEye.x, rightEye.y + 3, 6, up: true)
                arc(50, 64, 11, up: false, 3.5)
            }

            if sleeping { // z's in place of the badge: 0,1,2,3 z's on a 2 s loop (frame 0 blank); all three when static
                let n = t.map { Int($0 / 0.5) % 4 } ?? 3
                for i in 0..<n {
                    outer.draw(Text("z").font(.system(size: CGFloat(18 - i * 3), weight: .black)).foregroundColor(.white.opacity(0.9 - Double(i) * 0.2)),
                             at: CGPoint(x: 80 + CGFloat(i) * 8, y: 28 - CGFloat(i) * 10))
                }
                return
            }

            // state badge, top-right
            let badge: (String, Color, CGFloat)
            switch state {
            case .idle: badge = ("z", .gray, 15)
            case .working: badge = ("···", .blue, 13)
            case .needsYou: badge = ("!", .orange, 15)
            case .done: badge = ("✓", .green, 15)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: 58, y: 0, width: 42, height: 42)), with: .color(badge.1))
            ctx.draw(Text(badge.0).font(.system(size: 28, weight: .black)).foregroundColor(.white),
                     at: CGPoint(x: 79, y: badge.2 + 6))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
