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
    }

    /// Glance text: who finished (repo · branch), so several threads can be told apart.
    private var compactText: String {
        guard let d = model.doneItems.last else { return model.state.title }
        return "\(d.identity) · finished"
    }

    /// Content beside the camera: icon in the left wing, text in the right wing, nothing under the cutout.
    private var headerTitle: String {
        if model.pending.isEmpty { return model.state.title }
        let n = model.pending.count
        return n > 1 ? "Needs you · 1 of \(n)" : "Needs you"
    }

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
                    Text(headerTitle).font(.headline).foregroundStyle(.white)
                }
                if let req = model.pending.first {
                    ApprovalCard(req: req) { model.resolve(req.id, $0) }
                } else if model.pinnedOpen {
                    if model.sessions.isEmpty { Text("No agent sessions.").font(.caption).foregroundStyle(.white.opacity(0.6)) }
                    ForEach(model.sessions) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(row.project) · \(row.headline)").font(.caption.bold()).foregroundStyle(.white)
                            Text(row.detail).font(.caption2).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                } else {
                    ForEach(model.doneItems.reversed()) { d in DoneCard(item: d) { model.dismissDone(d.sessionId) } }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
    }
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
                ChipButton(title: "Allow", fill: .green) { decide(.allow) }
                ChipButton(title: "Deny", fill: .red) { decide(.deny) }
                ChipButton(title: "Always", fill: Color(white: 0.35)) { decide(.always) }
            }
            .padding(.top, 2)
        }
    }
}

/// Drawn by hand so it looks the same whether or not the panel is the key window.
struct ChipButton: View {
    let title: String
    let fill: Color
    let action: () -> Void

    var body: some View {
        Text(title).font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }
}

struct DoneCard: View {
    let item: DoneItem
    let dismiss: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.identity).font(.caption.bold()).foregroundStyle(.white)
                Text(item.files == 0 ? "Finished · no file edits" : "Finished · \(item.files) file\(item.files == 1 ? "" : "s") · +\(item.added) −\(item.removed)")
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            ChipButton(title: "Dismiss", fill: Color(white: 0.35), action: dismiss)
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
