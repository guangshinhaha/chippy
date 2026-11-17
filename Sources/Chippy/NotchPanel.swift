import AppKit
import ChippyCore
import Combine
import SwiftUI

/// Borderless panel docked top-center of the screen, over the notch.
final class NotchPanel: NSPanel {
    private let model: NotchModel
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
        contentView = NSHostingView(rootView: NotchView(model: model))
        model.$density.receive(on: RunLoop.main).sink { [weak self] d in self?.dock(d) }.store(in: &bag)
        dock(model.density)
    }

    override var canBecomeKey: Bool { true }

    static func size(for density: Density, notchWidth: CGFloat) -> CGSize {
        switch density {
        case .collapsed: return CGSize(width: notchWidth + 80, height: 34)
        case .compact: return CGSize(width: notchWidth + 160, height: 56)
        case .expanded: return CGSize(width: max(notchWidth + 200, 380), height: 200)
        }
    }

    func dock(_ density: Density) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let notch = (left > 0 && right > 0) ? screen.frame.width - left - right : 160
        let size = Self.size(for: density, notchWidth: notch)
        let f = screen.frame
        setFrame(CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height,
                        width: size.width, height: size.height), display: true)
    }
}
