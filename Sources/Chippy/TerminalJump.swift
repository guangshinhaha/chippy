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

    /// Only plain tty names reach the script text.
    static func validTTY(_ s: String?) -> String? {
        guard let s, s.range(of: "^ttys[0-9]{1,5}\\z", options: .regularExpression) != nil else { return nil }
        return s
    }

    /// AppleScript that selects the tab/session on `tty`; nil for apps without a reliable scripting path.
    static func script(bundle: String, tty: String) -> String? {
        guard let dev = validTTY(tty) else { return nil }
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

    /// Orca: after it is frontmost, ask its CLI (from the running app's own bundle) to select the session's workspace
    /// (it has no AppleScript). Reports what the CLI answered; `completion` runs on the main queue.
    static func selectOrcaWorkspace(_ cwd: String, appBundleURL: URL?, completion: @escaping (OrcaCLI.Select) -> Void) {
        func finish(_ s: OrcaCLI.Select) {
            if case .failed(let why) = s { NSLog("Chippy: Orca workspace select failed (%@)", why) }
            if s == .unconfirmed { NSLog("Chippy: Orca workspace select gave no readable answer, judged by exit code only") }
            DispatchQueue.main.async { completion(s) }
        }
        guard let cli = OrcaCLI.cliURL(appBundleURL: appBundleURL),
              FileManager.default.isExecutableFile(atPath: cli.path) else { finish(.failed("orca CLI not found in the running app")); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            let out = Pipe()
            p.executableURL = cli
            p.arguments = OrcaCLI.arguments(cwd: cwd)
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { finish(.failed("could not run the orca CLI")); return }
            // A hung CLI must not strand the jump: give up after 5s (the read below then ends when it dies).
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationReason == .exit else { finish(.failed("timed out")); return }
            finish(OrcaCLI.interpret(exitStatus: p.terminationStatus, stdout: data))
        }
    }

    /// `.landed` when the host app is frontmost with a window on the visible Space (polled for up to ~3s);
    /// `.offSpace` when it is frontmost but its windows stayed on another Space (no reopen is attempted);
    /// `.notFrontmost` when it could not be brought forward. Known limit: we cannot
    /// tell which of the app's windows is the session's, only that one is visible.
    static func open(_ host: HostInfo?, completion: @escaping (ActivationOutcome.Verdict) -> Void = { _ in }) {
        guard available(host), let h = host, let pid = h.pid, let bundle = h.bundle else { completion(.notFrontmost); return }
        let activate = {
            bringForward(pid: pid) { v in
                guard v == .landed || v == .landedUnverified, bundle == OrcaCLI.bundleId, let cwd = h.cwd else { completion(v); return }
                let url = NSRunningApplication(processIdentifier: pid)?.bundleURL
                selectOrcaWorkspace(cwd, appBundleURL: url) { completion(OrcaCLI.finalVerdict(v, select: $0)) }
            }
        }
        guard let src = script(bundle: bundle, tty: h.tty ?? "") else { activate(); return }
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
