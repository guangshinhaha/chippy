import Foundation

/// Pure policy for "keep the Mac awake while agents work" (#40). No system calls here.
public enum AwakePolicy {
    public static let debounce: TimeInterval = 30
    public static let lowBatteryPercent = 20

    /// Hold while working/needsYou, and for `debounce` seconds after the last such moment.
    /// `lastWorking` is the last time the state was working or needsYou (nil = never).
    public static func shouldHold(state: ChippyState, lastWorking: Date?, now: Date,
                                  debounce: TimeInterval = AwakePolicy.debounce) -> Bool {
        if state == .working || state == .needsYou { return true }
        guard let last = lastWorking else { return false }
        return now.timeIntervalSince(last) < debounce
    }

    /// Crash recovery: a leftover marker means a previous run may have died with SleepDisabled=1.
    public static func shouldClearOnLaunch(markerExists: Bool) -> Bool { markerExists }

    /// Lid-closed mode must not drain a battery: release below 20% when not on AC.
    /// A Mac with no battery (percent nil) never trips this.
    public static func batteryTooLow(percent: Int?, onAC: Bool) -> Bool {
        guard let p = percent, !onAC else { return false }
        return p < lowBatteryPercent
    }

    public enum Lid: Equatable { case off, on, lowBattery }

    /// Desired disablesleep value for lid-closed mode.
    public static func lidDecision(hold: Bool, lidModeEnabled: Bool, percent: Int?, onAC: Bool) -> Lid {
        guard hold, lidModeEnabled else { return .off }
        return batteryTooLow(percent: percent, onAC: onAC) ? .lowBattery : .on
    }
}

/// The one-time sudoers rule and the shell text that installs it. Pure text; nothing here touches /etc.
public enum SudoersRule {
    public static let path = "/etc/sudoers.d/chippy-pmset"

    /// macOS short names: ASCII letters, digits, `_`, `-`, `.`; must not start with `-` or `.`. Rejects anything
    /// that could inject sudoers or shell syntax (spaces, commas, `#`, quotes, `%`, `!`, newlines).
    public static func isValidUser(_ u: String) -> Bool {
        guard !u.isEmpty, u.count <= 32, let f = u.unicodeScalars.first, f != "-", f != "." else { return false }
        return u.unicodeScalars.allSatisfy { s in
            guard s.value < 128 else { return false }
            return CharacterSet.alphanumerics.contains(s) || s == "_" || s == "-" || s == "."
        }
    }

    /// Exactly: `<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1`
    public static func line(user: String) -> String? {
        guard isValidUser(user) else { return nil }
        return "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    }

    /// True only for the exact line generated for `user` (guards against a tampered rule).
    public static func isExpected(_ text: String, user: String) -> Bool {
        guard let l = line(user: user) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == l
    }

    /// Root shell script for the admin prompt. Validates with `visudo -cf` BEFORE moving into place;
    /// on any failure `set -e` aborts, the trap removes the temp file, and /etc/sudoers.d is untouched.
    public static func installScript(user: String) -> String? {
        guard let l = line(user: user) else { return nil }
        return "set -e; t=$(/usr/bin/mktemp /tmp/chippy-sudoers.XXXXXX); "
            + "trap '/bin/rm -f \"$t\"' EXIT; "
            + "/usr/bin/printf '%s\\n' '\(l)' > \"$t\"; "
            + "/usr/sbin/visudo -cf \"$t\"; "
            + "/usr/sbin/chown root:wheel \"$t\"; /bin/chmod 0440 \"$t\"; "
            + "/bin/mv \"$t\" \(path)"
    }

    public static let removeScript = "/bin/rm -f \(path)"

    /// Wrap a shell script as AppleScript source for `NSAppleScript` (escapes backslash and quote).
    public static func appleScript(forShell script: String) -> String {
        let esc = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(esc)\" with administrator privileges"
    }
}
