import Foundation

/// Keep-awake mode (#60). Raw values are persisted under `keepAwake.mode`.
public enum AwakeMode: String, CaseIterable, Equatable {
    case off, agents, agentsLid

    public var label: String {
        switch self {
        case .off: return "Off"
        case .agents: return "While agents work"
        case .agentsLid: return "While agents work, even lid closed"
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
}

public extension AwakePolicy {
    /// One-time migration from the old `keepAwake.enabled` / `keepAwake.lidClosed` booleans.
    /// Lid mode without the sudoers setup migrates to `agents`, so the stored mode is always one the menu can show.
    static func migrate(enabled: Bool, lidClosed: Bool, setupInstalled: Bool = true) -> AwakeMode {
        guard enabled else { return .off }
        return lidClosed && setupInstalled ? .agentsLid : .agents
    }

    /// The mode actually in force. At or past the deadline -> off; lid mode without setup -> agents.
    static func effectiveMode(mode: AwakeMode, until: Date?, now: Date, setupInstalled: Bool) -> AwakeMode {
        if mode != .off, let until, now >= until { return .off }
        if mode == .agentsLid, !setupInstalled { return .agents }
        return mode
    }

    /// Whether keep-awake needs its 5s re-check (#180): only while an effective mode is on. It ends a deadline, lets the debounce
    /// release the assertion, and re-reads the battery for lid-closed mode; with the mode off (or just expired) none of that exists.
    /// One exception: while a `disablesleep 0` is still owed (`clearPending`: SleepDisabler holds the setting or its marker) the timer
    /// keeps running, because after a failed clear that tick is the only retry. Without it a Mac could stay unable to sleep with the lid closed.
    static func needsTimer(effective: AwakeMode, clearPending: Bool) -> Bool { effective != .off || clearPending }

    /// The battery matters only to lid-closed mode (`lidDecision` ignores it otherwise), so only that mode reads it.
    static func needsBattery(effective: AwakeMode) -> Bool { effective == .agentsLid }

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
