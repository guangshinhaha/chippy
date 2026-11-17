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
                    Text(model.sessions.first?.detail ?? model.state.title)
                        .font(.caption.bold()).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.tail)
                    if model.sessions.count > 1 {
                        Text("+\(model.sessions.count - 1)").font(.caption2).foregroundStyle(.white.opacity(0.6))
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
                    Text(model.state.title).font(.headline).foregroundStyle(.white)
                }
                if let req = model.pending.first {
                    ApprovalCard(req: req, more: model.pending.count - 1) { model.resolve(req.id, $0) }
                }
                if model.sessions.isEmpty && model.pending.isEmpty {
                    Text("No agent sessions.").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                ForEach(model.sessions) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(row.project) · \(row.headline)").font(.caption.bold()).foregroundStyle(.white)
                        Text(row.detail).font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
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
    let more: Int
    let decide: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(req.project) needs you").font(.caption2).foregroundStyle(.white.opacity(0.6))
            Text(req.ask).font(.system(.caption, design: .monospaced)).foregroundStyle(.white).lineLimit(3)
            HStack {
                Button("Allow") { decide(.allow) }.tint(.green)
                Button("Deny") { decide(.deny) }.tint(.red)
                Button("Always") { decide(.always) }
                if more > 0 { Text("+\(more) more").font(.caption2).foregroundStyle(.white.opacity(0.6)) }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
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
