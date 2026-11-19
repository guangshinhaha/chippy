import AppKit
import ChippyCore

/// "Open terminal" on a finished chip: bring the hosting app to the front, and select the exact tab where
/// scripting makes that reliable (iTerm2, Terminal.app). Everything else just activates the app.
enum TerminalJump {
    /// The host is still running and is the same app (guards against a recycled pid).
    static func available(_ host: HostInfo?) -> Bool {
        guard let h = host, h.hasHost, let pid = h.pid,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        return app.bundleIdentifier == h.bundle
    }

    /// Brings `pid`'s app forward and reports whether it ended up frontmost.
    /// Plain `activate` can be a no-op (app hidden, windows minimised, or focus not yielded to it), so:
    /// unhide, yield activation to the target (macOS 14+), activate, then check; if still not frontmost,
    /// ask LaunchServices to open it (activates and sends the reopen event that un-minimises a window).
    /// "Landed" also needs one of the app's windows on the visible Space: macOS switches to the window's Space on
    /// activation only when Desktop & Dock > "When switching to an application, switch to a Space with open
    /// windows" is on. There is no supported API to switch Space ourselves; if it stays off-Space the jump reports failure.
    static func bringForward(pid: Int32, completion: @escaping (ActivationOutcome.Verdict) -> Void) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { completion(.notFrontmost); return }
        let bundle = app.bundleIdentifier
        /// All processes of the host app, computed once per jump.
        let pids: Set<Int32> = bundle.map { Set(NSRunningApplication.runningApplications(withBundleIdentifier: $0).map { $0.processIdentifier }).union([pid]) } ?? [pid]
        var unreadable = false
        func verdict() -> ActivationOutcome.Verdict {
            let front = NSWorkspace.shared.frontmostApplication
            // Same app counts even if the frontmost pid differs (multi-process hosts).
            let frontmost = ActivationOutcome.isFrontmost(frontmostPid: front?.processIdentifier, target: pid)
                || (bundle != nil && front?.bundleIdentifier == bundle)
            guard frontmost else { return .notFrontmost }   // window list only once the app is frontmost
            var counts: WindowScan.Counts?
            if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
                counts = WindowScan.counts(in: list, pids: pids)
            } else { unreadable = true }
            return ActivationOutcome.verdict(frontmost: true, counts: counts)
        }
        /// Checks every 0.15s up to `window` seconds (a Space-switch animation takes a while); stops at the first
        /// frontmost+visible verdict. Gives the last verdict otherwise.
        func poll(for window: TimeInterval, _ done: @escaping (ActivationOutcome.Verdict) -> Void) {
            let deadline = Date().addingTimeInterval(window)
            func step() {
                let v = verdict()
                if v == .landed || v == .landedUnverified || Date() >= deadline { done(v); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step() }
        }
        /// One log line per jump, after the polling ends.
        func finish(_ v: ActivationOutcome.Verdict, _ err: Error? = nil) {
            switch v {
            case .landed, .workspaceNotSelected: break   // the latter is only produced after this step, by the host's own select
            case .landedUnverified:
                NSLog("Chippy: window check inconclusive for %@ (%@), judged by frontmost only", bundle ?? "?", unreadable ? "window list unreadable" : "no windows found for its processes")
            case .offSpace:
                NSLog("Chippy: app frontmost but its windows are on another Space (check System Settings > Desktop & Dock > \"When switching to an application, switch to a Space with open windows\")")
            case .notFrontmost:
                NSLog("Chippy: open terminal failed for pid %d (%@): %@", pid, bundle ?? "?", String(describing: err))
            }
            completion(v)
        }
        if app.isHidden { app.unhide() }
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
        _ = app.activate(options: [])
        poll(for: 1.5) { v in
            // Already frontmost (windows just elsewhere): reopening would not move a Space, so report it as is.
            if v != .notFrontmost { finish(v); return }
            guard let url = app.bundleURL else { finish(v); return }
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                DispatchQueue.main.async { poll(for: 1.5) { finish($0, err) } }
            }
        }
    }

    /// Opens a link in the host app itself (not whichever app owns the scheme), so a second build cannot take it.
    /// `completion` runs on the main queue with what LaunchServices answered.
    static func openURL(_ url: URL, in appURL: URL?, completion: @escaping (JumpPlan.StepResult) -> Void) {
        guard let appURL else { completion(.failed("host app bundle not found")); return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            DispatchQueue.main.async {
                completion(err.map { e in let n = e as NSError; return .failed(JumpPlan.reason(errorDomain: n.domain, code: n.code)) } ?? .done)
            }
        }
    }

    /// Runs a host's CLI (from the running app's own bundle) as the exact-target step and reports what it answered.
    /// Reads the answer with `OrcaCLI.interpret` (exit code plus an `ok` flag). `completion` runs on the main queue.
    static func runCLI(_ cli: URL, arguments: [String], completion: @escaping (JumpPlan.StepResult) -> Void) {
        func finish(_ s: OrcaCLI.Select) {
            if s == .unconfirmed { NSLog("Chippy: host CLI step gave no readable answer, judged by exit code only") }
            DispatchQueue.main.async { completion(s.step) }
        }
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { finish(.failed("host CLI not found in the running app")); return }
        DispatchQueue.global(qos: .userInitiated).async { finish(HostProcess.run(cli, arguments)) } // ends on exit, capped at 5s (#136)
    }

    /// Reads a small file under the home folder: at most 256 bytes, so a swapped-in FIFO or huge file cannot freeze anything.
    /// Call off the main thread.
    static func readHomeFile(_ relative: String) -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative)
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        return (try? h.read(upToCount: 256)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `.landed` when the host app is frontmost with a window on the visible Space (polled for up to ~3s);
    /// `.offSpace` when it is frontmost but its windows stayed on another Space (no reopen is attempted);
    /// `.notFrontmost` when it could not be brought forward; `.workspaceNotSelected` when the app came forward but
    /// the host's own exact-target step failed. Known limit: we cannot tell which of the app's windows is the session's,
    /// only that one is visible.
    ///
    /// What is exact per host is not decided here: `HostAdapters.plan` says (activate only, a tty script, a CLI, or a link)
    /// and this runs it.
    static func open(_ host: HostInfo?, completion: @escaping (ActivationOutcome.Verdict) -> Void = { _ in }) {
        guard available(host), let h = host, let pid = h.pid else { completion(.notFrontmost); return }
        let appURL = NSRunningApplication(processIdentifier: pid)?.bundleURL
        // The plan reads a small file for some hosts, so it is built off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let plan = HostAdapters.plan(for: h, context: JumpContext(appBundleURL: appURL, readHomeFile: readHomeFile))
            DispatchQueue.main.async { run(plan, pid: pid, appURL: appURL, completion: completion) }
        }
    }

    private static func run(_ plan: JumpPlan, pid: Int32, appURL: URL?, completion: @escaping (ActivationOutcome.Verdict) -> Void) {
        let activate = {
            bringForward(pid: pid) { v in
                guard v == .landed || v == .landedUnverified else { completion(v); return }
                // One place logs every failed exact-target step; each reason is a fixed string or an error domain and code, never an id.
                func step(_ r: JumpPlan.StepResult) {
                    if case .failed(let why) = r { NSLog("Chippy: exact-target step failed (%@), app left in front", why) }
                    completion(JumpPlan.finalVerdict(v, step: r))
                }
                switch plan {
                case .activate, .appleScript: completion(v)
                case .cli(let exe, let args): runCLI(exe, arguments: args, completion: step)
                case .openURL(let url): openURL(url, in: appURL, completion: step)
                case .exactTargetUnavailable(let why): step(.failed(why))
                }
            }
        }
        guard case .appleScript(let src) = plan else { activate(); return }
        // osascript off the main thread: the first run may sit on the Automation permission prompt.
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", src]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                // A hung target app or an unanswered permission prompt must not strand the jump: give up after 5s.
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
                p.waitUntilExit()
            }   // on failure we still activate below
            DispatchQueue.main.async { activate() }
        }
    }
}
