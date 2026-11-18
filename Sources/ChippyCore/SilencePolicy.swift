import Foundation

/// Injected quiet state (#95). The app layer reads it; this module only decides. Screen recording is deferred
/// (no public detection API).
public struct SilenceState: Equatable {
    public var focus: Bool
    public var locked: Bool
    public init(focus: Bool = false, locked: Bool = false) { self.focus = focus; self.locked = locked }
    public var isQuiet: Bool { focus || locked }
}

/// Quiet means: no sound and no auto-expanding card. It never hides a request: a needs-you still shows on the
/// badge, stays pending and answerable, and the hook's own timeout still hands an approval to the terminal.
public enum SilencePolicy {
    public static func soundsAllowed(_ s: SilenceState) -> Bool { !s.isQuiet }
    /// Whether a new approval/question may open the card by itself. When false it arrives folded onto the badge.
    public static func mayAutoExpand(_ s: SilenceState) -> Bool { !s.isQuiet }
    /// Whether a finished chip may peek open by itself. When false it stays on the collapsed badge.
    public static func mayPeek(_ s: SilenceState) -> Bool { !s.isQuiet }

    /// Parses ~/Library/DoNotDisturb/DB/Assertions.json: Focus is on when any assertion record exists.
    /// Unreadable or unknown shape is "off" (fail open: behaves as before this feature). Reads no user content.
    public static func focusIsOn(assertionsJSON data: Data?) -> Bool {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return false }
        return list.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
    }
}
