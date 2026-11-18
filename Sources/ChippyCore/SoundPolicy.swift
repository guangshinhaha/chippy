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
    /// The pid may be a child of the terminal, so a matching bundle id also counts.
    public static func isHostFrontmost(host: HostInfo?, frontmostPid: Int32?, frontmostBundle: String?) -> Bool {
        guard let host else { return false }
        if let pid = host.pid, pid == frontmostPid { return true }
        if let b = host.bundle, b == frontmostBundle { return true }
        return false
    }
}

/// Last-played times, per session AND per kind, so a done Tink never suppresses a needs-you Pop.
public struct SoundCooldowns {
    private var last: [String: [SoundKind: Date]] = [:]
    public init() {}
    public func lastPlayed(_ kind: SoundKind, session: String) -> Date? { last[session]?[kind] }
    public mutating func record(_ kind: SoundKind, session: String, at: Date) { last[session, default: [:]][kind] = at }
    /// Drop a finished session's entries.
    public mutating func prune(session: String) { last[session] = nil }
    public var sessionCount: Int { last.count }
}
