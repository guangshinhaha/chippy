import CoreGraphics

/// Free space on each side of the camera cutout, measured from menu bar item frames (screen coordinates,
/// same space as `notch`). Pure so it can be tested; the app feeds it frames from the window server.
public enum MenuBarGap {
    /// Below this the compact strip is not worth drawing: only the small collapsed pill shows.
    public static let minUsable: CGFloat = 60
    /// Breathing room kept between the pill and the nearest menu item.
    public static let padding: CGFloat = 6

    /// Left and right free width beside `notch`. An item counts for the side its centre is on; an item
    /// overlapping the notch leaves that side with no gap. `screen` bounds the open side when a side has no items.
    public static func wings(items: [CGRect], notch: CGRect, screen: CGRect) -> (left: CGFloat, right: CGFloat) {
        var left = notch.minX - screen.minX
        var right = screen.maxX - notch.maxX
        for r in items where !r.isEmpty && r.intersects(CGRect(x: screen.minX, y: notch.minY, width: screen.width, height: max(notch.height, 1))) {
            if r.midX < notch.midX { left = min(left, notch.minX - r.maxX) }
            else { right = min(right, r.minX - notch.maxX) }
        }
        return (max(0, left - padding), max(0, right - padding))
    }
}
