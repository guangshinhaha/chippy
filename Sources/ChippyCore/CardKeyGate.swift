import Foundation

/// Pure decisions for the card hotkeys and Esc while a reply field may hold focus (#94). AppDelegate asks; nothing else decides.
public enum CardKeyGate {
    /// Card hotkeys (Y/N/digits) may be registered only for a shown card and never while the reply field has focus.
    public static func shouldRegisterHotKeys(hasShownCard: Bool, replyFieldFocused: Bool) -> Bool {
        hasShownCard && !replyFieldFocused
    }

    /// Esc anywhere folds the detail, except while the reply field has focus (there it only leaves the field).
    public static func escShouldFold(replyFieldFocused: Bool) -> Bool { !replyFieldFocused }
}
