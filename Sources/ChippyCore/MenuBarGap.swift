import CoreGraphics

/// Free space on each side of the camera cutout, measured from menu bar item frames (screen coordinates,
/// same space as `notch`). Pure so it can be tested; the app feeds it frames from the window server.
public enum MenuBarGap {
    /// Below this the compact strip is not worth drawing: only the small collapsed pill shows.
    public static let minUsable: CGFloat = 60
    /// Breathing room kept between the pill and the nearest menu item.
    public static let padding: CGFloat = 6

    /// With no way to read the frontmost app's menus, the left side is assumed to hold them: never claim more than this.
    public static let unmeasuredLeftCap: CGFloat = 100
    /// Gaps closer than this (pt) are the same measurement; unbounded (infinity) is a value that equals itself.
    public static let tolerance: CGFloat = 2

    public static func same(_ a: CGFloat, _ b: CGFloat) -> Bool { a == b || abs(a - b) <= tolerance }
    public static func same(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Bool { same(a.0, b.0) && same(a.1, b.1) }

    /// The notch rect in the same (CG, top-left origin) space as `screen`, centred on that screen's own frame.
    public static func notchRect(screen: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: screen.midX - width / 2, y: screen.minY, width: width, height: height)
    }

    /// Left and right free width beside `notch`. An item counts for the side its centre is on; an item
    /// overlapping the notch leaves that side with no gap. `screen` bounds the open side when a side has no items.
    public static func wings(items: [CGRect], notch: CGRect, screen: CGRect, leftMeasured: Bool = true) -> (left: CGFloat, right: CGFloat) {
        var left = notch.minX - screen.minX
        var right = screen.maxX - notch.maxX
        if !leftMeasured { left = min(left, unmeasuredLeftCap) }
        for r in items where !r.isEmpty && r.intersects(CGRect(x: screen.minX, y: notch.minY, width: screen.width, height: max(notch.height, 1))) {
            if r.midX < notch.midX { left = min(left, notch.minX - r.maxX) }
            else { right = min(right, r.minX - notch.maxX) }
        }
        return (max(0, left - padding), max(0, right - padding))
    }
}
