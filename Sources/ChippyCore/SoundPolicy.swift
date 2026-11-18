import Foundation

public enum SoundKind: Equatable { case needsYou, done }

/// Pure policy for subtle sounds (#67). AppKit reads frontmost/lock state and plays; this decides.
public enum SoundPolicy {
    public static let cooldown: TimeInterval = 2

    /// `lastPlayed` is when this session last made a sound (nil = never). Cooldown is per session.
    public static func shouldPlay(kind: SoundKind, enabled: Bool, hostFrontmost: Bool, locked: Bool,
                                  lastPlayed: Date?, now: Date) -> Bool {
        guard enabled, !hostFrontmost, !locked else { return false }
        if let last = lastPlayed, now.timeIntervalSince(last) < cooldown { return false }
        return true
    }

    /// Host app is frontmost: match by pid, fall back to bundle id when there is no pid.
    public static func isHostFrontmost(host: HostInfo?, frontmostPid: Int32?, frontmostBundle: String?) -> Bool {
        guard let host else { return false }
        if let pid = host.pid { return pid == frontmostPid }
        if let b = host.bundle { return b == frontmostBundle }
        return false
    }
}
