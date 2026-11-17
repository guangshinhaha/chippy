import ChippyCore
import SwiftUI

/// Chippy's static look for a state, sized like the old placeholder icon.
struct StateIcon: View {
    let state: ChippyState
    var size: CGFloat = 18

    var body: some View {
        ChipmunkView(state: state).frame(width: size * 1.4, height: size * 1.4)
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var box: MetricsBox

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape().fill(.black)
            content.padding(.bottom, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggleOpen() }
        .animation(motion, value: model.density)
        .animation(motion, value: model.pending.count)
        .animation(motion, value: model.tall)
    }

    private func report(_ h: CGFloat) {
        DispatchQueue.main.async { if h > 0, abs(box.contentHeight - h) > 0.5 { box.contentHeight = h } }
    }

    /// Short ease-out, interruptible; off when the user asked for reduced motion.
    private var motion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18)
    }

    /// Glance text: who finished (repo · branch), so several threads can be told apart.
    private var compactText: String {
        guard let d = model.doneItems.last else { return model.state.title }
        return d.glance(showReply: model.showReplyInGlance)
    }

    private var headerTitle: String {
        if model.pending.isEmpty { return model.state.title }
        let n = model.pending.count
        return n > 1 ? "Needs you · 1 of \(n)" : "Needs you"
    }

    /// Content beside the camera: icon in the left wing, text in the right wing, nothing under the cutout.
    @ViewBuilder
    var content: some View {
        let m = box.metrics
        switch model.density {
        case .collapsed:
            HStack(spacing: 0) {
                StateIcon(state: model.state).padding(.leading, 10)
                Spacer(minLength: 0)
            }
            .frame(height: m.band, alignment: .center)
        case .compact:
            let wing = m.wing(for: .compact)
            HStack(spacing: 0) {
                HStack { StateIcon(state: model.state); Spacer(minLength: 0) }
                    .padding(.leading, 10).frame(width: wing)
                Color.clear.frame(width: m.width)
                HStack(spacing: 6) {
                    Text(compactText)
                        .font(.caption.bold()).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.tail)
                    if model.doneItems.count > 1 {
                        Text("+\(model.doneItems.count - 1)").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(width: wing)
            }
            .frame(height: m.band, alignment: .center)
            .frame(maxHeight: .infinity, alignment: .top)
        case .expanded:
            VStack(alignment: .leading, spacing: 8) {
                Spacer().frame(height: box.metrics.height + 2)
                HStack(spacing: 10) {
                    StateIcon(state: model.state, size: 28)
                    Text(headerTitle).font(.headline.monospacedDigit()).foregroundStyle(.white)
                }
                if let req = model.pending.first {
                    if req.questions != nil {
                        QuestionCard(req: req) { model.answer(req.id, $0) }.id(req.id)
                    } else {
                        ApprovalCard(req: req) { model.resolve(req.id, $0) }
                    }
                } else if model.pinnedOpen {
                    ForEach(model.doneItems.reversed().prefix(3)) { d in DoneCard(item: d) { model.dismissDone(d.sessionId) } }
                    if model.sessions.isEmpty { Text("No agent sessions.").font(.caption).foregroundStyle(.white.opacity(0.6)) }
                    ForEach(model.sessions) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(row.project) · \(row.headline)").font(.caption.bold()).foregroundStyle(.white)
                            Text(row.detail).font(.caption2).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                } else {
                    ForEach(model.doneItems.reversed().prefix(model.tall ? 1 : 3)) { d in DoneCard(item: d, full: model.tall) { model.dismissDone(d.sessionId) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .background(GeometryReader { g in Color.clear.onAppear { report(g.size.height) }.onChange(of: g.size.height) { report($0) } })
        }
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ApprovalCard: View {
    let req: PendingRequest
    let decide: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(req.branch.map { "\(req.project) · \($0)" } ?? req.project)
                .font(.caption.bold()).foregroundStyle(.white.opacity(0.85))
            if let p = req.lastPrompt, !p.isEmpty {
                Text("“\(p)”").font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            Text("\(req.toolName) wants to run").font(.caption2).foregroundStyle(.white.opacity(0.6))
            Text(req.detail.isEmpty ? req.toolName : req.detail)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.white)
                .lineLimit(4).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(req.cwd).font(.caption2).foregroundStyle(.white.opacity(0.4)).lineLimit(1).truncationMode(.head)
            HStack(spacing: 8) {
                ChipButton(title: "Allow", kind: .primary) { decide(.allow) }
                ChipButton(title: "Deny", kind: .destructive) { decide(.deny) }
                Spacer(minLength: 0)
                ChipButton(title: "Always allow this", kind: .quiet) { decide(.always) }
            }
            .padding(.top, 2)
        }
    }
}

/// Drawn by hand (system bordered buttons vanish in a non-key panel). Press scales to 0.96, hover lifts, 28pt tall
/// with a larger hit area than it draws.
struct ChipButton: View {
    enum Kind { case primary, destructive, neutral, quiet }
    let title: String
    let kind: Kind
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(ChipStyle(kind: kind, hover: hover))
            .onHover { hover = $0 }
    }
}

struct ChipStyle: ButtonStyle {
    let kind: ChipButton.Kind
    let hover: Bool

    private var fill: Color {
        switch kind {
        case .primary: return Color.green.opacity(hover ? 0.95 : 0.8)
        case .destructive: return Color.red.opacity(hover ? 0.32 : 0.2)
        case .neutral: return Color.white.opacity(hover ? 0.22 : 0.14)
        case .quiet: return Color.white.opacity(hover ? 0.1 : 0)
        }
    }
    private var text: Color {
        switch kind {
        case .primary: return .black
        case .destructive: return Color(red: 1, green: 0.55, blue: 0.5)
        case .neutral: return .white
        case .quiet: return .white.opacity(0.6)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(kind == .quiet ? .regular : .semibold)).foregroundStyle(text)
            .padding(.horizontal, 12).frame(minHeight: 28)
            .background(Capsule().fill(fill))
            .padding(4).contentShape(Rectangle()).padding(-4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Claude's own multiple-choice question. Pick an option per question; the last pick sends the answers.
struct QuestionCard: View {
    let req: PendingRequest
    let send: ([String: String]) -> Void
    @State private var step = 0
    @State private var answers: [String: String] = [:]
    @State private var sent = false

    var body: some View {
        let qs = req.questions ?? []
        let q = qs[min(step, qs.count - 1)]
        VStack(alignment: .leading, spacing: 6) {
            Text(req.branch.map { "\(req.project) · \($0)" } ?? req.project)
                .font(.caption.bold()).foregroundStyle(.white.opacity(0.85))
            Text(qs.count > 1 ? "\(q.header.isEmpty ? "Question" : q.header) · \(step + 1) of \(qs.count)" : (q.header.isEmpty ? "Claude asks" : q.header))
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
            Text(q.question).font(.caption.bold()).foregroundStyle(.white).lineLimit(3)
            ForEach(Array(q.options.enumerated()), id: \.offset) { _, o in
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.label).font(.caption.bold()).foregroundStyle(.white)
                    if !o.description.isEmpty { Text(o.description).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.18)))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !sent else { return } // a double-click must not answer the next question too
                    answers[q.question] = o.label
                    if step + 1 < qs.count { step += 1 } else { sent = true; send(answers) }
                }
            }
            Text("Or answer in the terminal").font(.caption2).foregroundStyle(.white.opacity(0.4))
        }
    }
}

struct DoneCard: View {
    let item: DoneItem
    var full = false
    let dismiss: () -> Void

    private var replyText: AttributedString {
        let r = item.reply ?? ""
        return (try? AttributedString(markdown: r, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(r)
    }

    private var replyBody: some View {
        Text(replyText).font(.caption).foregroundStyle(.white.opacity(0.92)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.identity + (item.asksYou ? " · waiting for your reply" : " · finished"))
                .font(.caption.bold()).foregroundStyle(item.asksYou ? Color.orange : .white)
            if full, let p = item.prompt, !p.isEmpty {
                Text("You asked: \(p)").font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            if let r = item.reply, !r.isEmpty {
                if full {
                    // Short reply: just the text (the card hugs it). Long reply: scrolls inside a capped area.
                    ViewThatFits(in: .vertical) {
                        replyBody
                        ScrollView { replyBody }
                    }
                    .frame(maxHeight: 290)
                } else {
                    Text(r).font(.caption).foregroundStyle(.white.opacity(0.9)).lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Text(item.files == 0 ? "No file edits" : "\(item.files) file\(item.files == 1 ? "" : "s") · +\(item.added) −\(item.removed)")
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
                Spacer()
                ChipButton(title: "Dismiss", kind: .neutral, action: dismiss)
            }
        }
    }
}

/// Flat top edge (flush with the screen), rounded bottom corners.
struct NotchShape: Shape {
    var radius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
