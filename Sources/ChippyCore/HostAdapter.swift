import Foundation

/// What the jump does to land on the session's exact spot once its host app is known (#140). Pure data: AppKit runs it.
public enum JumpPlan: Equatable {
    /// Nothing exact to select: bring the app forward and stop.
    case activate
    /// Run this script before activating (selects a Terminal/iTerm tab by tty).
    case appleScript(String)
    /// Run a CLI after the app is frontmost (Orca selects the worktree).
    case cli(executable: URL, arguments: [String])
    /// Open a link in the host app after it is frontmost (T3 Code opens the thread).
    case openURL(URL)
    /// The host has an exact target but it cannot be built (CLI or id missing). Reported as not landed, never as success.
    case exactTargetUnavailable(String)

    /// What an exact-target step answered once it ran.
    public enum StepResult: Equatable {
        case done
        /// It ran but its answer could not be read: we cannot confirm it.
        case unconfirmed
        /// It did not run, was refused, timed out or answered no. The reason is for the log only.
        case failed(String)
    }

    /// A log-safe reason for a step an OS error stopped: its domain and code only. The error's own description can carry
    /// the URL, which holds thread and environment ids.
    public static func reason(errorDomain: String, code: Int) -> String { "\(errorDomain) \(code)" }

    /// What the jump reports once the exact-target step has been tried. One path for every host: app-level failures pass
    /// through untouched, and a failed step is never "landed".
    public static func finalVerdict(_ app: ActivationOutcome.Verdict, step: StepResult) -> ActivationOutcome.Verdict {
        guard app == .landed || app == .landedUnverified else { return app }
        switch step {
        case .done: return app
        case .unconfirmed: return .landedUnverified
        case .failed: return .workspaceNotSelected
        }
    }
}

/// What a plan may read from the machine. Injected so tests never touch the disk.
public struct JumpContext {
    /// The running host app's bundle, for CLIs shipped inside it. nil when the app is gone.
    public let appBundleURL: URL?
    /// A small file under the home folder (path relative to it), or nil if unreadable.
    public let readHomeFile: (String) -> String?
    public init(appBundleURL: URL?, readHomeFile: @escaping (String) -> String?) {
        self.appBundleURL = appBundleURL; self.readHomeFile = readHomeFile
    }
}

/// One host app: how to recognise it, which env vars the hook forwards, and what its jump does.
/// Adding a host is adding an entry to `HostAdapters.standard`; the hook, `HostInfo` and `TerminalJump` do not change.
public struct HostAdapter {
    public let bundleId: String
    /// Names of the env vars the hook forwards for this host. Values are checked with `T3Link.validId` rules (letters, digits, `_`, `-`).
    public let forwardedEnv: [String]
    public let plan: (HostInfo, JumpContext) -> JumpPlan
    public init(bundleId: String, forwardedEnv: [String] = [], plan: @escaping (HostInfo, JumpContext) -> JumpPlan) {
        self.bundleId = bundleId; self.forwardedEnv = forwardedEnv; self.plan = plan
    }
}

public enum HostAdapters {
    public static let standard: [HostAdapter] = [
        HostAdapter(bundleId: "com.apple.Terminal") { h, _ in TTYScripts.plan(bundle: "com.apple.Terminal", tty: h.tty) },
        HostAdapter(bundleId: "com.googlecode.iterm2") { h, _ in TTYScripts.plan(bundle: "com.googlecode.iterm2", tty: h.tty) },
        HostAdapter(bundleId: OrcaCLI.bundleId) { h, c in
            guard let cwd = h.cwd else { return .activate }
            guard let cli = OrcaCLI.cliURL(appBundleURL: c.appBundleURL) else { return .exactTargetUnavailable("orca CLI not found in the running app") }
            return .cli(executable: cli, arguments: OrcaCLI.arguments(cwd: cwd))
        },
        HostAdapter(bundleId: T3Link.bundleId, forwardedEnv: [T3Link.threadEnvName]) { h, c in
            guard let thread = T3Link.threadId(for: h) else { return .activate }
            let env = T3Link.environmentId(fileContents: c.readHomeFile(T3Link.environmentIdPath))
            guard let url = T3Link.url(environmentId: env, threadId: thread) else { return .exactTargetUnavailable("T3 environment id unreadable") }
            return .openURL(url)
        },
    ]

    public static func adapter(for bundle: String?, in table: [HostAdapter] = standard) -> HostAdapter? {
        guard let bundle else { return nil }
        return table.first { $0.bundleId == bundle }
    }

    /// The jump for this host. An unknown app, or no host, only activates.
    public static func plan(for host: HostInfo?, context: JumpContext, in table: [HostAdapter] = standard) -> JumpPlan {
        guard let h = host, let a = adapter(for: h.bundle, in: table) else { return .activate }
        return a.plan(h, context)
    }

    /// Hook side: only the vars the recognised host names, only values that are safe to forward.
    public static func forwardedEnv(bundle: String?, environment: [String: String], in table: [HostAdapter] = standard) -> [String: String] {
        guard let a = adapter(for: bundle, in: table) else { return [:] }
        return clean(environment, names: a.forwardedEnv)
    }

    /// Chippy side: the same filter applied again to what arrived over the socket.
    public static func sanitize(_ raw: Any?, bundle: String?, in table: [HostAdapter] = standard) -> [String: String] {
        guard let a = adapter(for: bundle, in: table), let dict = raw as? [String: Any] else { return [:] }
        return clean(dict.compactMapValues { $0 as? String }, names: a.forwardedEnv)
    }

    private static func clean(_ source: [String: String], names: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for n in names { if let v = T3Link.validId(source[n]) { out[n] = v } }
        return out
    }
}

/// The AppleScript that selects the tab/session on a tty, for hosts with a reliable scripting path.
public enum TTYScripts {
    /// Only plain tty names reach the script text.
    public static func validTTY(_ s: String?) -> String? {
        guard let s, s.range(of: "^ttys[0-9]{1,5}\\z", options: .regularExpression) != nil else { return nil }
        return s
    }

    public static func plan(bundle: String, tty: String?) -> JumpPlan {
        guard let dev = validTTY(tty), let src = script(bundle: bundle, dev: dev) else { return .activate }
        return .appleScript(src)
    }

    static func script(bundle: String, dev: String) -> String? {
        switch bundle {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "/dev/\(dev)" then
                    set selected of t to true
                    set index of w to 1
                    return
                  end if
                end repeat
              end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "/dev/\(dev)" then
                      select w
                      select t
                      select s
                      return
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        default: return nil
        }
    }
}
