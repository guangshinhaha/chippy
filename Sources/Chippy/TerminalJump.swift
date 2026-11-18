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
    static func bringForward(pid: Int32, completion: @escaping (Bool) -> Void) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { completion(false); return }
        func isFront() -> Bool {
            ActivationOutcome.isFrontmost(frontmostPid: NSWorkspace.shared.frontmostApplication?.processIdentifier, target: pid)
        }
        if app.isHidden { app.unhide() }
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
        _ = app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if isFront() { completion(true); return }
            guard let url = app.bundleURL else { completion(false); return }
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let ok = isFront()
                    if !ok { NSLog("Chippy: open terminal failed for pid %d (%@): %@", pid, app.bundleIdentifier ?? "?", String(describing: err)) }
                    completion(ok)
                }
            }
        }
    }

    /// `completion(true)` when the host app is frontmost afterwards, false when it could not be brought forward.
    static func open(_ host: HostInfo?, completion: @escaping (Bool) -> Void = { _ in }) {
        guard available(host), let h = host, let pid = h.pid, let bundle = h.bundle else { completion(false); return }
        let activate = { bringForward(pid: pid, completion: completion) }
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
