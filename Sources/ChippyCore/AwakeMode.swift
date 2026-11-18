import Foundation

/// Keep-awake mode (#60). Raw values are persisted under `keepAwake.mode`.
public enum AwakeMode: String, CaseIterable, Equatable {
    case off, agents, agentsLid

    public var label: String {
        switch self {
        case .off: return "Off"
        case .agents: return "While agents work"
        case .agentsLid: return "While agents work, lid closed"
        }
    }
}

/// How long a non-off mode may run. `until` is stored as an absolute epoch deadline.
public enum AwakeDuration: Int, CaseIterable, Equatable {
    case indefinite = 0, oneHour = 3600, twoHours = 7200, fourHours = 14400

    public var label: String {
        switch self {
        case .indefinite: return "Until I turn it off"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .fourHours: return "4 hours"
        }
    }

    /// Absolute deadline for this duration picked at `now` (nil = no deadline).
    public func deadline(from now: Date) -> Date? {
        self == .indefinite ? nil : now.addingTimeInterval(TimeInterval(rawValue))
    }

    /// Which preset the stored deadline corresponds to, for the radio group: the smallest preset
    /// that is not shorter than what remains; nil deadline = indefinite.
    public static func closest(until: Date?, now: Date) -> AwakeDuration {
        guard let until else { return .indefinite }
        let left = until.timeIntervalSince(now)
        for d in [AwakeDuration.oneHour, .twoHours, .fourHours] where left <= TimeInterval(d.rawValue) { return d }
        return .fourHours
    }
}

public extension AwakePolicy {
    /// One-time migration from the old `keepAwake.enabled` / `keepAwake.lidClosed` booleans.
    static func migrate(enabled: Bool, lidClosed: Bool) -> AwakeMode {
        guard enabled else { return .off }
        return lidClosed ? .agentsLid : .agents
    }

    /// The mode actually in force. At or past the deadline -> off; lid mode without setup -> agents.
    static func effectiveMode(mode: AwakeMode, until: Date?, now: Date, setupInstalled: Bool) -> AwakeMode {
        if mode != .off, let until, now >= until { return .off }
        if mode == .agentsLid, !setupInstalled { return .agents }
        return mode
    }

    /// "1h 20m", "45m", "<1m" for the time left until `until`.
    static func timeLeftText(until: Date, now: Date) -> String {
        let secs = until.timeIntervalSince(now)
        if secs < 60 { return "<1m" }
        let mins = Int((secs / 60).rounded(.up))
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// Parent menu row title: `Keep Mac awake: <state>` plus ` · 1h 20m left` while a deadline runs.
    static func parentTitle(mode: AwakeMode, until: Date?, now: Date) -> String {
        var t = "Keep Mac awake: \(mode.label)"
        if mode != .off, let until, until > now { t += " · \(timeLeftText(until: until, now: now)) left" }
        return t
    }
}
