import ChippyCore
import SwiftUI

/// Placeholder per-state look; real mascot art lands in #6.
struct StateIcon: View {
    let state: ChippyState
    var size: CGFloat = 18

    var symbol: String {
        switch state {
        case .idle: return "moon.zzz.fill"
        case .working: return "gearshape.2.fill"
        case .needsYou: return "exclamationmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch state {
        case .idle: return .gray
        case .working: return .blue
        case .needsYou: return .orange
        case .done: return .green
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .foregroundStyle(color)
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape().fill(.black)
            content.padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    var content: some View {
        switch model.density {
        case .collapsed:
            HStack { StateIcon(state: model.state); Spacer() }
        case .compact:
            HStack(spacing: 8) {
                StateIcon(state: model.state)
                Spacer()
                Text(model.sessions.first?.detail ?? model.state.title)
                    .font(.caption.bold()).foregroundStyle(.white).lineLimit(1)
                if model.sessions.count > 1 {
                    Text("+\(model.sessions.count - 1)").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
        case .expanded:
            VStack(alignment: .leading, spacing: 8) {
                Spacer().frame(height: 28)
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
