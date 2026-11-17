import CoreGraphics

/// The camera cutout of the screen the panel sits on. Notch size differs per Mac (14" vs 16" vs Air),
/// and external displays and older Macs have none, so it is measured (see `detect` in the app), never assumed.
public struct NotchMetrics: Equatable {
    public var width: CGFloat   // 0 when the screen has no notch
    public var height: CGFloat  // camera housing height, or the menu-bar height when there is none
    public var hasNotch: Bool { width > 0 }

    public init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }

    public static let none = NotchMetrics(width: 0, height: 24)
    public static let sample14 = NotchMetrics(width: 185, height: 32) // for the gallery

    /// The tallest the expanded card ever gets (the `contentHeight` cap in `size`).
    public static let maxExpandedHeight: CGFloat = 560

    /// Height of the strip beside the camera, where collapsed and compact content lives.
    public var band: CGFloat { max(height + 2, 30) }

    /// `contentHeight` is the measured height of the expanded card, so the shape hugs it instead of leaving dead space.
    public func size(for density: Density, tall: Bool = false, contentHeight: CGFloat = 0) -> CGSize {
        switch density {
        case .collapsed: return CGSize(width: width + 2 * 48, height: band)
        case .compact: return CGSize(width: width + 2 * 190, height: band + 14)
        case .expanded: return CGSize(width: max(width + 220, tall ? 460 : 380), height: contentHeight > 0 ? min(max(contentHeight + 10, 120), Self.maxExpandedHeight) : (tall ? 470 : 300) + (height - 28))
        }
    }

    /// The fixed host-window size: big enough for every shape the island can take on this screen.
    public var maxSize: CGSize {
        let all = [size(for: .collapsed), size(for: .compact), size(for: .expanded, tall: false), size(for: .expanded, tall: true)]
        return CGSize(width: all.map(\.width).max() ?? 0,
                      height: max(Self.maxExpandedHeight, all.map(\.height).max() ?? 0))
    }

    /// Usable width on each side of the camera.
    public func wing(for density: Density) -> CGFloat { (size(for: density).width - width) / 2 }
}
