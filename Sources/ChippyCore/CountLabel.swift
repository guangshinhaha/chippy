import Foundation

/// Short count text for tight spots (#212): above `cap` it shows "cap+", so a huge count cannot widen the compact notch.
/// Display only: VoiceOver labels keep the real number. The collapsed badge has its own "9+" rule (#86).
public enum CountLabel {
    public static func short(_ n: Int, cap: Int = 99) -> String {
        let cap = max(cap, 0)
        if n <= 0 { return "0" }
        return n > cap ? "\(cap)+" : "\(n)"
    }
}
