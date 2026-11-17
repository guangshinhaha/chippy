import Foundation

/// Pure rules for keyboard shortcuts on the notch card (no Carbon, no UI).
public enum ShortcutGate {
    /// A shortcut is ignored until the card has been on screen this long, so keys typed into
    /// another app a moment ago can't answer a card the user hasn't read.
    public static let minimumVisible: TimeInterval = 0.6

    public static func allows(shownAt: Date?, now: Date = Date()) -> Bool {
        guard let shownAt else { return false }
        return now.timeIntervalSince(shownAt) >= minimumVisible
    }

    /// Digit keys 1...9 map to option indexes 0...; a key beyond the option count is ignored.
    public static func optionIndex(forKey key: Int, optionCount: Int) -> Int? {
        guard key >= 1, key <= 9, key <= optionCount else { return nil }
        return key - 1
    }
}
