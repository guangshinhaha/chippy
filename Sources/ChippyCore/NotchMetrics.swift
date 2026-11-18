import CoreGraphics

/// The camera cutout of the screen the panel sits on. Notch size differs per Mac (14" vs 16" vs Air),
/// and external displays and older Macs have none, so it is measured (see `detect` in the app), never assumed.
public struct NotchMetrics: Equatable {
    public var width: CGFloat   // 0 when the screen has no notch
    public var height: CGFloat  // camera housing height, or the menu-bar height when there is none
    public var hasNotch: Bool { width > 0 }
    /// Free menu-bar space beside the camera (see `MenuBarGap`); unbounded until measured.
    public var leftGap: CGFloat = .infinity
    public var rightGap: CGFloat = .infinity

    public init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }

    /// The pill is symmetric about the camera, so the narrower side sets both wings.
    private var gap: CGFloat { hasNotch ? min(leftGap, rightGap) : .infinity }
    /// The glance chipmunk's size; the badge and tab layout are measured from it.
    public static let glanceIcon: CGFloat = 18 * 1.4
    /// Gap between the glance icon and a badge beside it (tab mode).
    public static let badgeGap: CGFloat = 8
    /// Narrowest wing that still holds the chipmunk (10pt inset + icon).
    public static let minIconWing: CGFloat = 36
    /// The collapsed pill's wing: its usual 48pt, clamped to the gap so it never covers an item.
    private var collapsedWing: CGFloat { min(48, max(gap, 0)) }
    /// False when the gap is under `MenuBarGap.minUsable` (60pt): compact then shows the collapsed pill instead.
    public var compactFits: Bool { gap >= MenuBarGap.minUsable }

    /// Where the collapsed/compact indicator lives.
    public enum Placement: Equatable {
        case wings(CGFloat) // beside the camera, this wide on each side
        case tab            // no room beside the camera: a small tab hanging below it
    }
    /// Height of the tab below the menu bar band.
    public static let tabHeight: CGFloat = 26
    /// Sideways while a wing can hold the icon; otherwise a tab under the camera, so the indicator never vanishes.
    public var placement: Placement { hasNotch && collapsedWing < Self.minIconWing ? .tab : .wings(collapsedWing) }
    public var isTab: Bool { placement == .tab }

    public static let none = NotchMetrics(width: 0, height: 24)
    public static let sample14 = NotchMetrics(width: 185, height: 32) // for the gallery

    /// The tallest the expanded card ever gets (the `contentHeight` cap in `size`).
    public static let maxExpandedHeight: CGFloat = 560

    /// Height of the strip beside the camera, where collapsed and compact content lives.
    public var band: CGFloat { max(height + 2, 30) }

    /// Width of the resting tab on a screen with no notch (nothing to hang from, so a small pill at top-centre).
    public static let flatRestingWidth: CGFloat = 52

    /// The resting indicator (#85): always a tab, never wings (wings would cover other apps' menus).
    /// Notch: the tab hanging under the camera. No notch: a small pill the height of the menu bar, centred.
    public var restingSize: CGSize {
        hasNotch ? CGSize(width: width, height: band + Self.tabHeight) : CGSize(width: Self.flatRestingWidth, height: max(height, Self.glanceIcon + 4))
    }

    /// Size of the shape for a density, or of the resting tab when `resting` (only meaningful for collapsed).
    public func size(for density: Density, resting: Bool, tall: Bool = false, contentHeight: CGFloat = 0) -> CGSize {
        resting && density == .collapsed ? restingSize : size(for: density, tall: tall, contentHeight: contentHeight)
    }

    /// `contentHeight` is the measured height of the expanded card, so the shape hugs it instead of leaving dead space.
    public func size(for density: Density, tall: Bool = false, contentHeight: CGFloat = 0) -> CGSize {
        switch density {
        case .collapsed:
            if isTab { return CGSize(width: width, height: band + Self.tabHeight) }
            return CGSize(width: width + 2 * collapsedWing, height: band)
        case .compact:
            if isTab { return size(for: .collapsed) }
            guard compactFits else { return size(for: .collapsed) }
            return CGSize(width: width + 2 * min(190, gap), height: band + 14)
        case .expanded: return CGSize(width: max(width + 220, tall ? 460 : 380), height: contentHeight > 0 ? min(max(contentHeight + 10, 120), Self.maxExpandedHeight) : (tall ? 470 : 300) + (height - 28))
        }
    }

    /// The fixed host-window size: big enough for every shape the island can take on this screen.
    public var maxSize: CGSize {
        var free = self; free.leftGap = .infinity; free.rightGap = .infinity // the window never depends on the gap
        let all = [free.size(for: .collapsed), free.size(for: .compact), free.size(for: .expanded, tall: false), free.size(for: .expanded, tall: true)]
        return CGSize(width: all.map(\.width).max() ?? 0,
                      height: max(Self.maxExpandedHeight, all.map(\.height).max() ?? 0))
    }

    /// Usable width on each side of the camera.
    public func wing(for density: Density) -> CGFloat { (size(for: density).width - width) / 2 }
}
