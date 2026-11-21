import Foundation

/// Short count text for tight spots (#212): above `cap` it shows "cap+", so a huge count cannot widen the compact notch.
/// Display only: VoiceOver labels keep the real number. The collapsed badge has its own "9+" rule (#86).
public enum CountLabel {
    public static func short(_ n: Int, cap: Int = 99) -> String {
        let cap = max(cap, 0)
        if n <= 0 { return "0" }
        return n > cap ? "\(cap)+" : "\(n)"
    }

    /// "1 session" / "2 sessions" (C29): the singular branch at n == 1, for visible text and spoken labels alike.
    /// `plural` overrides the default `noun + "s"`.
    public static func counted(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? noun : (plural ?? noun + "s"))
    }
}
