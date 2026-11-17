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
        guard let s, s.range(of: "^ttys[0-9]{1,5}$", options: .regularExpression) != nil else { return nil }
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

    static func open(_ host: HostInfo?) {
        guard available(host), let h = host, let pid = h.pid, let bundle = h.bundle else { return }
        let activate = { _ = NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
        guard let src = script(bundle: bundle, tty: h.tty ?? "") else { activate(); return }
        // osascript off the main thread: the first run may sit on the Automation permission prompt.
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", src]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()   // on failure we still activate below
            DispatchQueue.main.async { activate() }
        }
    }
}
