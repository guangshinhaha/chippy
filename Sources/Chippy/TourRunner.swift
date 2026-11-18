import AppKit
import ChippyCore
import SwiftUI

/// Runs the tour (#27): the existing `chippy-hook demo` cards in sequence. Demo sessions (`demo-*`) are never logged.
@MainActor
final class TourRunner {
    /// Read by the notch to pick the done-card caption. Set when a tour starts.
    static var hooksConnected = true

    private let model: NotchModel
    private var running = false
    private var current: Process?
    /// Called once when the first-launch tour ends (or fails to start), so other launch prompts can wait for it.
    var onFinish: (() -> Void)?

    init(model: NotchModel) { self.model = model }

    static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }

    /// True when the first-launch tour is about to run.
    var willRunOnFirstLaunch: Bool { !UserDefaults.standard.bool(forKey: Tour.defaultsKey) }

    private func finish() { let f = onFinish; onFinish = nil; f?() }

    func runOnFirstLaunch() {
        guard willRunOnFirstLaunch else { return }
        // Give the socket server a moment to come up. Mark the tour seen only once a step really launched.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.start() == true { UserDefaults.standard.set(true, forKey: Tour.defaultsKey) } else { self?.finish() }
        }
    }

    /// True when the first step was launched.
    @discardableResult
    func start() -> Bool {
        guard !running, let exe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("chippy-hook") else { return false }
        running = true
        model.debugLock = false
        Self.hooksConnected = Tour.hooksConnected(settingsText: try? String(contentsOf: Self.settingsURL, encoding: .utf8))
        run(Tour.steps[...], exe: exe)
        return running
    }

    private func run(_ rest: ArraySlice<Tour.Step>, exe: URL) {
        guard let step = rest.first else { running = false; finish(); return }
        let next = { [weak self] in
            // Short beat so the next card doesn't replace the last one mid-click.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.run(rest.dropFirst(), exe: exe) }
        }
        let p = Process(); p.executableURL = exe; p.arguments = ["demo", step.rawValue]
        if step == .done {
            // The done demo exits at once; its card stays until dismissed (or the step times out).
            guard (try? p.run()) != nil else { running = false; finish(); return }
            waitForDismiss(deadline: Date().addingTimeInterval(Tour.stepTimeout), seen: false, then: next)
        } else {
            // Approval and question demos exit when answered (or after their own 60s wait).
            p.terminationHandler = { _ in DispatchQueue.main.async { next() } }
            guard (try? p.run()) != nil else { running = false; finish(); return }
            current = p
        }
    }

    private func waitForDismiss(deadline: Date, seen: Bool, then: @escaping () -> Void) {
        // The card appears a moment after the process starts, so "dismissed" only counts once it was seen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let present = self.model.doneItems.contains { Tour.isDemo($0.sessionId) }
            if (seen && !present) || Date() > deadline { self.running = false; then() }
            else { self.waitForDismiss(deadline: deadline, seen: seen || present, then: then) }
        }
    }

    /// Connect step: runs the existing `chippy-hook install` in Terminal. It shows the diff and asks; nothing is written silently.
    static func connect() {
        guard let exe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("chippy-hook") else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chippy-connect.command")
        do {
            try Tour.connectScript(binary: exe.path).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch { return }
        NSWorkspace.shared.open(url)
    }
}

/// One-line coach caption under a demo card; renders nothing for real sessions.
struct TourCaption: View {
    let sessionId: String
    let step: Tour.Step

    var body: some View {
        let connected = TourRunner.hooksConnected
        if let text = Tour.caption(sessionId: sessionId, step: step, connected: connected) {
            HStack(spacing: 8) {
                Text(text).font(.caption2).foregroundStyle(Color.yellow.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                if step == .done && !connected {
                    ChipButton(title: "Connect", kind: .primary) { TourRunner.connect() }
                }
            }
        }
    }
}
