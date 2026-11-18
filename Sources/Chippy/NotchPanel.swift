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

/// Measures the menu bar gap beside the camera. Other apps' menu extras are layer 25 windows (bounds need no
/// permission). The frontmost app's menus are NOT windows, so they are read from its AXMenuBar only when
/// Accessibility is already trusted (never prompted); otherwise the left gap is capped conservatively.
/// Runs off the main thread, on app/space/screen events and a slow timer, never per frame.
enum MenuBarProbe {
    static func windowFrames(screenWidth: CGFloat) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 24 || layer == 25,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"] else { return nil }
            return wd < screenWidth / 2 && ht < 60 ? CGRect(x: x, y: y, width: wd, height: ht) : nil
        }
    }

    /// Frames (global CG space) of the frontmost app's menu bar items, or nil when they cannot be read.
    static func appMenuFrames(pid: pid_t) -> [CGRect]? {
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return nil }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let items = kids as? [AXUIElement] else { return nil }
        let frames: [CGRect] = items.compactMap { el in
            var pos: CFTypeRef?, size: CFTypeRef?
            var p = CGPoint.zero, sz = CGSize.zero
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
                  let pos, let size,
                  AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &sz) else { return nil }
            return CGRect(origin: p, size: sz)
        }
        return frames.isEmpty ? nil : frames
    }

    static func gaps(notchWidth: CGFloat, notchHeight: CGFloat, displayID: CGDirectDisplayID, frontPID: pid_t?) -> (CGFloat, CGFloat) {
        let screen = CGDisplayBounds(displayID) // this screen's own frame in CG space, wherever it sits
        let notch = MenuBarGap.notchRect(screen: screen, width: notchWidth, height: notchHeight)
        let app = frontPID.flatMap(appMenuFrames(pid:))
        let g = MenuBarGap.wings(items: windowFrames(screenWidth: screen.width) + (app ?? []), notch: notch, screen: screen, leftMeasured: app != nil)
        return (g.left, g.right)
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
    /// `measured` is the latest stable reading; `gaps` is what the shape uses. They meet only when idle.
    private var measured: (CGFloat, CGFloat) = (.infinity, .infinity)
    private var gaps: (CGFloat, CGFloat) = (.infinity, .infinity)
    private var gapTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var lastDensityChange = Date.distantPast

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
        model.$density.receive(on: RunLoop.main).sink { [weak self] d in
            guard let self else { return }
            self.lastDensityChange = Date()
            if d != .expanded { self.gaps = self.measured } // a new gap is applied as the density changes, not under an open card
            self.dock(d)
        }.store(in: &bag)
        metrics.$contentHeight.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.dock(self?.model.density ?? .collapsed) }.store(in: &bag)
        model.$tall.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.dock(self?.model.density ?? .collapsed) }.store(in: &bag)
        model.$visible.receive(on: RunLoop.main).sink { [weak self] v in
            guard let self else { return }
            if v { self.dock(self.model.density); self.orderFrontRegardless(); self.remeasure(); self.startGapTimer() } else { self.orderOut(nil); self.gapTimer?.invalidate(); self.gapTimer = nil }
        }.store(in: &bag)
        dock(model.density)
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            nc.publisher(for: n).receive(on: RunLoop.main).sink { [weak self] _ in self?.remeasure() }.store(in: &bag)
        }
        remeasure()
        if model.visible { startGapTimer() }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.remeasure()
                self.dock(self.model.density)
            }.store(in: &bag)
    }

    private func startGapTimer() {
        guard gapTimer == nil else { return }
        gapTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.remeasure() } // events cover the rest
    }

    /// Re-read the menu bar gap off the main thread. A change must hold for 0.4s before it counts, so quick app
    /// switching does not make the pill spring repeatedly.
    private func remeasure() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let m = NotchMetrics.detect(screen)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let g = MenuBarProbe.gaps(notchWidth: m.width, notchHeight: m.height, displayID: id, frontPID: front)
            DispatchQueue.main.async { self?.consider(g) }
        }
    }

    private func consider(_ g: (CGFloat, CGFloat)) {
        if MenuBarGap.same(g, measured) { debounce?.cancel(); debounce = nil; return }
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.measured = g
            self.applyIfIdle()
        }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Never under an open card or mid-spring; otherwise a later density change picks the new gap up.
    private func applyIfIdle() {
        guard model.density != .expanded, Date().timeIntervalSince(lastDensityChange) > 0.8,
              !MenuBarGap.same(gaps, measured) else { return }
        gaps = measured
        dock(model.density)
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

    deinit { monitors.forEach { NSEvent.removeMonitor($0) }; gapTimer?.invalidate() }

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
        var m = NotchMetrics.detect(screen)
        (m.leftGap, m.rightGap) = gaps
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
