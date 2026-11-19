import Foundation

/// Where a Claude Code session runs: the GUI app that hosts it and the terminal device it is attached to.
/// In memory only; never written to events.jsonl.
public struct HostInfo: Equatable {
    public let pid: Int32?
    public let bundle: String?
    public let tty: String?   // e.g. "ttys004"
    public var cwd: String? = nil   // the session's working directory, to select its workspace in hosts like Orca
    public init(pid: Int32?, bundle: String?, tty: String?, cwd: String? = nil) { self.pid = pid; self.bundle = bundle; self.tty = tty; self.cwd = cwd }
    /// Something to jump to: a known host app.
    public var hasHost: Bool { pid != nil && bundle != nil }
}

/// Pure check behind the "Open terminal" feedback.
public enum ActivationOutcome {
    /// The jump worked when the target app is frontmost afterwards (already being frontmost counts).
    public static func isFrontmost(frontmostPid: Int32?, target: Int32) -> Bool { frontmostPid == target }

    public enum Verdict: Equatable {
        case notFrontmost
        case landed
        /// Frontmost, but the window check cannot say (no windows found for the host pids, e.g. helper-owned windows,
        /// or the window list was unreadable): judged by frontmost only.
        case landedUnverified
        /// Frontmost, but every window of the app is on another Space (or minimised).
        case offSpace
        /// The host app came forward but its own step to select the session's workspace failed (Orca CLI, #129).
        case workspaceNotSelected
    }

    /// `counts` is nil when the window list could not be read. Zero windows is inconclusive, never "landed".
    public static func verdict(frontmost: Bool, counts: WindowScan.Counts?) -> Verdict {
        guard frontmost else { return .notFrontmost }
        guard let c = counts, c.all > 0 else { return .landedUnverified }
        return c.onScreen > 0 ? .landed : .offSpace
    }
}

/// Pure ancestry walk, driven by lookup closures so it can be tested with a fake process table.
public enum ProcessTree {
    public static let maxSteps = 32

    /// A process counts as the host only if it is a regular app with a bundle id; otherwise the walk goes on to the real terminal.
    public static func isGUIHost(regularApp: Bool, bundleId: String?) -> Bool { regularApp && bundleId != nil }

    /// Walks from `start` up through parents. Stops at the first pid `isApp` accepts, at pid <= 1, on a cycle,
    /// or after `maxSteps` steps. `tty` is the nearest tty seen on the way (start included).
    public static func walk(start: Int32, parent: (Int32) -> Int32?, isApp: (Int32) -> Bool,
                            tty: (Int32) -> String?, maxSteps: Int = ProcessTree.maxSteps) -> (hostPid: Int32?, tty: String?) {
        var seen = Set<Int32>()
        var pid = start
        var foundTTY: String?
        for _ in 0..<maxSteps {
            guard pid > 1, seen.insert(pid).inserted else { break }
            if foundTTY == nil { foundTTY = tty(pid) }
            if isApp(pid) { return (pid, foundTTY) }
            guard let p = parent(pid) else { break }
            pid = p
        }
        return (nil, foundTTY)
    }
}

/// Pure parsing of CGWindowList dictionaries.
public enum WindowScan {
    public struct Counts: Equatable { public var all: Int; public var onScreen: Int
        public init(all: Int, onScreen: Int) { self.all = all; self.onScreen = onScreen } }

    /// Real windows of `pids`: owner in the set, layer 0, at least 100x50. `onScreen` = on the visible Space.
    public static func counts(in list: [[String: Any]], pids: Set<Int32>) -> Counts {
        var c = Counts(all: 0, onScreen: 0)
        for w in list {
            guard let owner = (w["kCGWindowOwnerPID"] as? NSNumber)?.int32Value, pids.contains(owner),
                  (w["kCGWindowLayer"] as? NSNumber)?.intValue == 0 else { continue }
            let b = w["kCGWindowBounds"] as? [String: Any] ?? [:]
            guard ((b["Width"] as? NSNumber)?.doubleValue ?? 0) >= 100, ((b["Height"] as? NSNumber)?.doubleValue ?? 0) >= 50 else { continue }
            c.all += 1
            if (w["kCGWindowIsOnscreen"] as? NSNumber)?.boolValue == true { c.onScreen += 1 }
        }
        return c
    }
}
