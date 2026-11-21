import AppKit
import SwiftUI
import ChippyCore

/// The menu bar "While you were away" window (#167): a normal window, so it works with the notch hidden or no notch at all.
/// It only reads `model.awayDigest`; closing it never dismisses or marks seen the notch's digest.
final class DigestWindowController {
    private var window: NSWindow?
    private let model: NotchModel

    init(model: NotchModel) { self.model = model }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "While you were away"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DigestWindowView(model: model))
            if !w.setFrameUsingName("ChippyDigestWindow") { w.center() } // keep where the user left it
            w.setFrameAutosaveName("ChippyDigestWindow")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct DigestWindowView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let rows = DigestWindowRows.rows(from: model.awayDigest)
        VStack(alignment: .leading, spacing: 0) {
            Text(DigestWindowRows.title(model.awayDigest)).font(.headline).padding([.horizontal, .top], 16).padding(.bottom, 8)
            if rows.isEmpty {
                Text("No agent finished or asked for you while you were away, or you already dealt with it.")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
                Spacer(minLength: 0)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    List(rows) { row in rowView(row, now: ctx.date) }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 200)
    }

    private func rowView(_ r: DigestWindowRow, now: Date) -> some View {
        let age = WaitingList.age(since: r.at, now: now)
        return HStack(spacing: 10) {
            Image(systemName: r.needsYou ? "exclamationmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(r.needsYou ? Color.orange : .secondary).frame(width: 18)
            IdentityMark(identity: model.marks.identity(repo: r.repo, resolved: r.resolved), size: 14)
            Text(r.name).bold().lineLimit(1).truncationMode(.middle).help(r.name)
            Text(r.ended ? "\(r.statusText) · ended" : r.statusText).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(age).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let t = r.target { Button("Open") { model.activate(t) } }
        }
        .padding(.vertical, 2)
    }
}
