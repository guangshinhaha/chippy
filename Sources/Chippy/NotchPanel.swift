import AppKit
import ChippyCore
import Combine
import SwiftUI

extension NotchMetrics {
    @MainActor static func detect(_ screen: NSScreen) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        guard top > 0, let l = screen.auxiliaryTopLeftArea?.width, let r = screen.auxiliaryTopRightArea?.width,
              l > 0, r > 0 else { return NotchMetrics(width: 0, height: max(NSStatusBar.system.thickness, 22)) }
        return NotchMetrics(width: screen.frame.width - l - r, height: top)
    }
}

final class MetricsBox: ObservableObject {
    @Published var metrics = NotchMetrics.none
    /// Natural height of the expanded content, reported by the view.
    @Published var contentHeight: CGFloat = 0
    /// Pointer is over the island (set by the panel's pointer tracking).
    @Published var hover = false
}

/// Borderless panel docked top-center of the screen, over the notch.
final class NotchPanel: NSPanel {
    private let model: NotchModel
    let metrics = MetricsBox()
    private var bag = Set<AnyCancellable>()

    init(model: NotchModel) {
        self.model = model
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: NotchView(model: model, box: metrics))
        host.sizingOptions = [] // the window is fixed; SwiftUI must not resize it
        contentView = host
        startPointerTracking()
        model.$density.receive(on: RunLoop.main).sink { [weak self] d in self?.dock(d) }.store(in: &bag)
        metrics.$contentHeight.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.dock(self?.model.density ?? .collapsed) }.store(in: &bag)
        model.$tall.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.dock(self?.model.density ?? .collapsed) }.store(in: &bag)
        model.$visible.receive(on: RunLoop.main).sink { [weak self] v in
            guard let self else { return }
            if v { self.dock(self.model.density); self.orderFrontRegardless() } else { self.orderOut(nil) }
        }.store(in: &bag)
        dock(model.density)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.dock(self.model.density)
            }.store(in: &bag)
    }

    override var canBecomeKey: Bool { true }

    /// Esc (when the notch has focus) folds an open detail.
    override func cancelOperation(_ sender: Any?) { model.closeDetail() }

    // MARK: click-through
    // The window is always the maximum size, so most of it is empty. Mouse events are accepted only while the
    // pointer is over the visible shape (plus a small margin for the hover grow); everywhere else the window
    // ignores them and clicks reach the menu bar and desktop. The pointer is tracked by event monitors because an
    // ignoring window receives no events itself.
    private var hitRect = CGRect.zero
    private var settleWork: DispatchWorkItem?
    private var monitors: [Any] = []

    private func startPointerTracking() {
        acceptsMouseMovedEvents = true
        let mask: NSEvent.EventTypeMask = [.mouseMoved]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.syncMouse() }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.syncMouse(); return e }) { monitors.append(l) }
    }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    private func syncMouse() {
        let inside = hitRect.contains(NSEvent.mouseLocation)
        if ignoresMouseEvents == inside { ignoresMouseEvents = !inside }
        if metrics.hover != inside { metrics.hover = inside } // an ignoring window gets no hover-exit, so hover comes from here
    }

    /// Where the pointer counts as "on the island": the larger of the old and new shape while it is moving.
    private func setHitRect(_ size: CGSize, screen: NSScreen, active: Bool) {
        let f = screen.frame
        let margin: CGFloat = 8
        var r = active ? CGRect(x: f.midX - size.width / 2 - margin, y: f.maxY - size.height - margin,
                                width: size.width + 2 * margin, height: size.height + margin) : .zero
        if active, !hitRect.isEmpty { r = r.union(hitRect) }
        hitRect = r
        syncMouse()
        settleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hitRect = active ? CGRect(x: f.midX - size.width / 2 - margin, y: f.maxY - size.height - margin,
                                           width: size.width + 2 * margin, height: size.height + margin) : .zero
            self.syncMouse()
        }
        settleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// Fixed frame (max size, top-centred on the notch screen). The shape animates inside it, so this never
    /// animates; it only runs again when the screen or the measured card height changes the hit area.
    func dock(_ density: Density) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let m = NotchMetrics.detect(screen)
        if metrics.metrics != m { metrics.metrics = m }
        let box = m.maxSize
        let f = screen.frame
        let frame = CGRect(x: f.midX - box.width / 2, y: f.maxY - box.height, width: box.width, height: box.height)
        if self.frame != frame { setFrame(frame, display: true) }
        // No notch: a collapsed island would sit over the menu bar, so it takes no clicks at all.
        let size = m.size(for: density, tall: model.tall, contentHeight: metrics.contentHeight)
        setHitRect(size, screen: screen, active: !(density == .collapsed && !m.hasNotch))
    }
}
