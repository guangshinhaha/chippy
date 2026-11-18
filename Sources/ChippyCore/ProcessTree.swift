import Foundation

/// Where a Claude Code session runs: the GUI app that hosts it and the terminal device it is attached to.
/// In memory only; never written to events.jsonl.
public struct HostInfo: Equatable {
    public let pid: Int32?
    public let bundle: String?
    public let tty: String?   // e.g. "ttys004"
    public init(pid: Int32?, bundle: String?, tty: String?) { self.pid = pid; self.bundle = bundle; self.tty = tty }
    /// Something to jump to: a known host app.
    public var hasHost: Bool { pid != nil && bundle != nil }
}

/// Pure check behind the "Open terminal" feedback.
public enum ActivationOutcome {
    /// The jump worked when the target app is frontmost afterwards (already being frontmost counts).
    public static func isFrontmost(frontmostPid: Int32?, target: Int32) -> Bool { frontmostPid == target }
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
