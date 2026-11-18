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
    static func appMenuFrames(pid: pid_t, trusted: Bool) -> [CGRect]? {
        guard trusted, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
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

    /// Raw frames, off the main thread. `app` is nil when Accessibility is untrusted or the read came back empty.
    static func read(frontPID: pid_t?, screenWidth: CGFloat) -> (windows: [CGRect], app: [CGRect]?, trusted: Bool) {
        let trusted = AXIsProcessTrusted() // once per probe
        return (windowFrames(screenWidth: screenWidth), frontPID.flatMap { appMenuFrames(pid: $0, trusted: trusted) }, trusted)
    }
}

final class MetricsBox: ObservableObject {
    @Published var metrics = NotchMetrics.none
    /// Natural height of the expanded content, reported by the view.
    @Published var contentHeight: CGFloat = 0
    /// Pointer is over the island (set by the panel's pointer tracking).
    @Published var hover = false
    /// Opens the shared status-item menu at the pointer (the header gear). Set by the panel.
    var openMenu: () -> Void = {}
}

/// Borderless panel docked top-center of the screen, over the notch.
final class NotchPanel: NSPanel {
    private let model: NotchModel
    let metrics = MetricsBox()
    private var bag = Set<AnyCancellable>()
    /// `gate` decides when a reading becomes the gap the shape uses; `gaps` is that applied value.
    private var gate = GapGate()
    private var gaps: (CGFloat, CGFloat) = (.infinity, .infinity)
    private var gapTimer: Timer?
    /// Last good read of the frontmost app's menus; an empty or stale read right after activation keeps it.
    private var appMenus = AppMenuCache()
    private let probeQueue = DispatchQueue(label: "chippy.menubar-probe", qos: .utility)
    private var probeGen = 0
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// Pops the app's one NSMenu (the status item's) at a screen point; `centered` puts it under the notch.
    var onMenu: ((_ at: NSPoint, _ centered: Bool) -> Void)?

    init(model: NotchModel) {
        self.model = model
        shapeDensity = model.density; shapeResting = model.resting
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        metrics.openMenu = { [weak self] in self?.onMenu?(NSEvent.mouseLocation, false) }
        let host = NSHostingView(rootView: NotchView(model: model, box: metrics))
        host.sizingOptions = [] // the window is fixed; SwiftUI must not resize it
        contentView = host
        startPointerTracking()
        // Density and resting change together in one refresh: both land here, and the second call finds nothing new,
        // so a transition docks (and starts or stops the gap timer) once.
        Publishers.Merge(model.$density.dropFirst().map { _ in () }, model.$resting.dropFirst().map { _ in () })
            .receive(on: RunLoop.main).sink { [weak self] in self?.shapeChanged() }.store(in: &bag)
        metrics.$contentHeight.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.dock(self?.model.density ?? .collapsed) }.store(in: &bag)
        // Opening the list is a click, so taking key focus (without activating the app) lets the arrow keys work at once.
        model.$listOpen.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] open in
            guard open, let self else { return }
            self.frontAtListOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.makeKey() // only on the open transition
        }.store(in: &bag)
        // The field only ever got key status by a click (#94): when its focus ends (Return, Esc, card gone/swapped, flag off)
        // the panel gives key status back at once, so the next keystroke goes to the terminal, not to Chippy.
        model.$replyFocusOwner.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] owner in
            if owner == nil { self?.releaseKeyAfterReply() }
        }.store(in: &bag)
        model.$tall.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.dock(self?.model.density ?? .collapsed) }.store(in: &bag)
        dock(model.density)
        orderFrontRegardless()
        let nc = NSWorkspace.shared.notificationCenter
        nc.publisher(for: NSWorkspace.activeSpaceDidChangeNotification).receive(on: RunLoop.main).sink { [weak self] _ in self?.remeasureIfVisible() }.store(in: &bag)
        nc.publisher(for: NSWorkspace.didActivateApplicationNotification).receive(on: RunLoop.main).sink { [weak self] _ in
            self?.remeasureIfVisible()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.remeasureIfVisible() } // the new app's menus may not be readable yet
        }.store(in: &bag)
        remeasure()
        if !model.resting { startGapTimer() }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.remeasure()
                self.dock(self.model.density)
            }.store(in: &bag)
    }

    private var shapeDensity: Density
    private var shapeResting: Bool

    /// Never hidden (#85). Resting costs nothing: no wings are drawn, so the gap is not measured and its timer is off.
    private func shapeChanged() {
        let d = model.density, r = model.resting
        guard d != shapeDensity || r != shapeResting else { return }
        if d != shapeDensity {
            // A stable pending gap rides along with this (already animating) density change, never under an open card.
            if let g = gate.densityChanged(expanded: d == .expanded, now: now) { gaps = g }
            schedulePoll(after: 0.85)
        }
        if r != shapeResting {
            if r { gapTimer?.invalidate(); gapTimer = nil } else { remeasure(); startGapTimer() }
        }
        shapeDensity = d; shapeResting = r
        dock(d)
    }

    private func startGapTimer() {
        gapTimer?.invalidate()
        gapTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.remeasure() } // events cover the rest
    }

    /// Re-read the menu bar gap off the main thread. A change must hold for 0.4s before it counts, so quick app
    /// switching does not make the pill spring repeatedly.
    private func remeasureIfVisible() { if !model.resting { remeasure() } }

    private func remeasure() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let m = NotchMetrics.detect(screen)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let bounds = CGDisplayBounds(id) // this screen's own frame in CG space, wherever it sits
        probeGen += 1
        let gen = probeGen
        probeQueue.async { [weak self] in
            let r = MenuBarProbe.read(frontPID: front, screenWidth: bounds.width)
            DispatchQueue.main.async {
                guard let self, gen == self.probeGen else { return } // a newer probe superseded this one
                self.consider(r, pid: front, bounds: bounds, metrics: m)
            }
        }
    }

    private func consider(_ r: (windows: [CGRect], app: [CGRect]?, trusted: Bool), pid: pid_t?, bounds: CGRect, metrics m: NotchMetrics) {
        // An empty or failed AX read keeps the last good one for the same app only (then the left is capped).
        let appMenus = self.appMenus.update(pid: pid, read: r.app, trusted: r.trusted)
        let barHeight = max(m.height, 24) + 2
        let items = MenuBarGap.plausible(r.windows + (appMenus ?? []), screen: bounds, menuBarHeight: barHeight)
        let notch = MenuBarGap.notchRect(screen: bounds, width: m.width, height: m.height)
        let g = MenuBarGap.wings(items: items, notch: notch, screen: bounds, leftMeasured: appMenus != nil)
        if let a = gate.observe((g.left, g.right), now: now) { apply(a) }
        if gate.hasPending { schedulePoll(after: 0.45) }
    }

    /// Re-evaluate a pending gap once the stability / settle windows have passed (it stays pending until then).
    private func schedulePoll(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let a = self.gate.poll(now: self.now) else { return }
            self.apply(a)
        }
    }

    /// The shape and icon already spring on the metrics change (NotchView animates `size`), so this needs no extra animation.
    private func apply(_ g: (CGFloat, CGFloat)) {
        gaps = g
        dock(model.density)
    }

    override var canBecomeKey: Bool { true }

    /// Accessibility identifier tagging the reply field, so its click can be told apart from any other view.
    static let replyFieldMarker = "chippy.replyField"

    /// True while the shared menu is popped up from this panel: the menu steals key focus, which must not read as
    /// "clicked elsewhere" (resignKey) or close the open panel under it. Set by the AppDelegate around `popUp`.
    var inMenuTracking = false

    /// Right-click or ctrl-click on the collapsed island opens the shared menu under the notch. Only reached while the
    /// pointer is over the shape (elsewhere the window ignores mouse events). The expanded card keeps its own clicks.
    override func sendEvent(_ event: NSEvent) {
        let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if secondary, model.density != .expanded {
            onMenu?(NSPoint(x: frame.midX, y: hitRect.minY + 8), true) // the shape's bottom edge (the hit rect adds an 8pt margin)
            return
        }
        // A click on the reply field takes key focus (without activating the app) so it can type. Only that click:
        // nowhere else does Chippy take the keyboard from the terminal.
        if event.type == .leftMouseDown, !isKeyWindow, model.freeTextReplyEnabled, model.shownPending?.questions != nil,
           var v = contentView?.hitTest(event.locationInWindow) {
            // Only the reply field (tagged by accessibility identifier) takes key; any other hit does nothing. UNVERIFIED live:
            // whether a click focuses a SwiftUI field in a non-activating panel, and whether the identifier reaches the AppKit view.
            var tagged = false
            while !tagged {
                tagged = v.accessibilityIdentifier() == Self.replyFieldMarker
                guard !tagged, let up = v.superview else { break }
                v = up
            }
            if tagged { makeKey() }
        }
        super.sendEvent(event)
    }

    /// Esc (when the notch has focus) folds an open detail.
    /// While a text field has focus (#94) Esc only leaves it: the card stays and the draft is kept.
    override func cancelOperation(_ sender: Any?) {
        if firstResponder is NSText { makeFirstResponder(nil); model.clearReplyFocus(); releaseKeyAfterReply(); return } // owner cleared first, so the release guard passes
        model.closeDetail()
    }

    /// Gives key status back after the reply field ends. A non-activating panel that stays key keeps eating the terminal's
    /// keystrokes, so it leaves the key window (order out, then back in front without key). The open list needs key, so it keeps it.
    private func releaseKeyAfterReply() {
        guard isKeyWindow, !model.listOpen, !model.replyFieldFocused else { return }
        if firstResponder is NSText { makeFirstResponder(nil) }
        orderOut(nil)
        orderFrontRegardless()
    }

    /// The list is keyboard-driven, so it must not outlive key focus: losing key (another window took it) closes it.
    /// Only a real hand-off counts (another app became frontmost since the list opened); transient losses, such as
    /// a menu or our own makeKey, are ignored. Clicking outside is closed by the AppDelegate's click monitor.
    private var frontAtListOpen: pid_t?
    override func resignKey() {
        super.resignKey()
        if !inMenuTracking { // the gear popup stealing key is not a hand-off
            if firstResponder is NSText { makeFirstResponder(nil) } // keystrokes now go elsewhere: drop the field's focus (the draft stays)
            model.clearReplyFocus()
        }
        guard model.listOpen, !inMenuTracking else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.model.listOpen, !self.inMenuTracking, !self.isKeyWindow else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if front != self.frontAtListOpen { self.model.closeList() }
        }
    }

    /// The waiting list is keyboard-driven (#53): arrows move, Return opens. Other keys pass through untouched.
    override func keyDown(with event: NSEvent) {
        if firstResponder is NSText { super.keyDown(with: event); return } // typing: never a list or card key
        guard model.listOpen, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 125: model.moveSelection(1)           // down
        case 126: model.moveSelection(-1)          // up
        case 36, 76: model.activateSelection()     // return, keypad enter
        default: super.keyDown(with: event)
        }
    }

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
        if metrics.hover != inside {
            metrics.hover = inside
            if inside, model.listOpen, !isKeyWindow { makeKey() } // a real mouse-enter on the list: keys reach it again (not every poll)
            model.setHover(inside)
        } // the peek holds while hovered; an ignoring window gets no hover-exit, so hover comes from here
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
        // No notch: a collapsed island (with a chip) would sit over the menu bar, so it takes no clicks. The resting
        // pill is the exception: a small fixed-width pill at top-centre, so Recent and the menu stay reachable.
        let resting = model.resting
        let size = m.size(for: density, resting: resting, tall: model.tall, contentHeight: metrics.contentHeight)
        setHitRect(size, screen: screen, active: resting || !(density == .collapsed && !m.hasNotch))
    }
}
