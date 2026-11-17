import AppKit
import ChippyCore
import Combine
import SwiftUI

/// The camera cutout of the screen the panel sits on. Notch size differs per Mac (14" vs 16" vs Air),
/// and external displays and older Macs have none, so it is measured, never assumed.
struct NotchMetrics: Equatable {
    var width: CGFloat   // 0 when the screen has no notch
    var height: CGFloat  // camera housing height, or the menu-bar height when there is none
    var hasNotch: Bool { width > 0 }

    static let none = NotchMetrics(width: 0, height: 24)
    static let sample14 = NotchMetrics(width: 185, height: 32) // for the gallery

    @MainActor static func detect(_ screen: NSScreen) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        guard top > 0, let l = screen.auxiliaryTopLeftArea?.width, let r = screen.auxiliaryTopRightArea?.width,
              l > 0, r > 0 else { return NotchMetrics(width: 0, height: max(NSStatusBar.system.thickness, 22)) }
        return NotchMetrics(width: screen.frame.width - l - r, height: top)
    }

    /// Height of the strip beside the camera, where collapsed and compact content lives.
    var band: CGFloat { max(height + 2, 30) }

    /// `contentHeight` is the measured height of the expanded card, so the panel hugs it instead of leaving dead space.
    func size(for density: Density, tall: Bool = false, contentHeight: CGFloat = 0) -> CGSize {
        switch density {
        case .collapsed: return CGSize(width: width + 2 * 48, height: band)
        case .compact: return CGSize(width: width + 2 * 190, height: band + 14)
        case .expanded: return CGSize(width: max(width + 220, tall ? 460 : 380), height: contentHeight > 0 ? min(max(contentHeight + 10, 120), 560) : (tall ? 470 : 300) + (height - 28))
        }
    }

    /// Usable width on each side of the camera.
    func wing(for density: Density) -> CGFloat { (size(for: density).width - width) / 2 }
}

final class MetricsBox: ObservableObject {
    @Published var metrics = NotchMetrics.none
    /// Natural height of the expanded content, reported by the view.
    @Published var contentHeight: CGFloat = 0
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
        contentView = NSHostingView(rootView: NotchView(model: model, box: metrics))
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

    /// Short, so resizing feels like a snap with a little give, not a slide.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.16 }

    /// Esc (when the notch has focus) folds an open detail.
    override func cancelOperation(_ sender: Any?) { model.closeDetail() }

    func dock(_ density: Density) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let m = NotchMetrics.detect(screen)
        if metrics.metrics != m { metrics.metrics = m }
        // No notch: a collapsed panel would sit over the menu bar, so let clicks through.
        ignoresMouseEvents = (density == .collapsed && !m.hasNotch)
        let size = m.size(for: density, tall: model.tall, contentHeight: metrics.contentHeight)
        let f = screen.frame
        let target = CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
        let animate = isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setFrame(target, display: true, animate: animate)
    }
}
