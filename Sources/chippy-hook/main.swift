import ChippyCore
import Darwin
import Foundation

// chippy-hook relay                       forward a Claude Code hook event to Chippy.app (fail-open)
// chippy-hook install [--settings P] [--yes] [--timeout SECS]   add hooks to ~/.claude/settings.json (backup + diff + confirm)

func debug(_ s: String) {
    if ProcessInfo.processInfo.environment["CHIPPY_HOOK_DEBUG"] != nil {
        FileHandle.standardError.write(Data("chippy-hook: \(s)\n".utf8))
    }
}

func relay(_ args: [String]) -> Never {
    var timeout = SettingsInstaller.defaultApprovalTimeout
    if let i = args.firstIndex(of: "--timeout"), i + 1 < args.count, let t = Int(args[i + 1]) { timeout = min(max(t, 1), 120) }
    let start = DispatchTime.now()
    func ms() -> String { String(format: "%.1fms", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6) }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    // Re-serialise compactly so the payload is exactly one line.
    guard let obj = try? JSONSerialization.jsonObject(with: input),
          let line = try? JSONSerialization.data(withJSONObject: obj) else {
        debug("unparseable payload, exit \(ms())"); exit(0)
    }
    guard let fd = SocketClient.connect() else {
        debug("Chippy.app not running, exit in \(ms())"); exit(0) // fail-open: agent never blocked
    }
    var snd = timeval(tv_sec: 1, tv_usec: 0) // a frozen app must not block the agent on a big payload
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))
    writeLine(fd: fd, line)
    let dict = obj as? [String: Any]
    let wantsAnswer = dict?["hook_event_name"] as? String == "PermissionRequest"
    guard wantsAnswer else { debug("relayed in \(ms())"); close(fd); exit(0) }

    // Wait for the notch to answer; on timeout or hang-up print nothing so the terminal prompt shows as normal.
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    guard let reply = readLine(fd: fd), let decision = try? JSONSerialization.jsonObject(with: reply) else {
        debug("no answer after \(ms()), falling back to terminal"); close(fd); exit(0)
    }
    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject: out)) ?? Data())
    debug("answered from notch in \(ms())")
    close(fd)
    exit(0)
}

func install(_ args: [String]) -> Never {
    var settingsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path
    var yes = false
    var timeout = SettingsInstaller.defaultApprovalTimeout
    var i = 0
    while i < args.count {
        if args[i] == "--yes" { yes = true }
        else if args[i] == "--timeout", i + 1 < args.count, let t = Int(args[i + 1]) { timeout = min(max(t, 1), 120); i += 1 }
        else if args[i] == "--settings", i + 1 < args.count { settingsPath = args[i + 1]; i += 1 }
        i += 1
    }
    let url = URL(fileURLWithPath: settingsPath)
    let oldData = (try? Data(contentsOf: url)) ?? Data()
    let old: [String: Any]
    if oldData.isEmpty { old = [:] }
    else if let o = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any] { old = o }
    else { print("error: \(settingsPath) is not valid JSON, not touching it"); exit(1) }

    // argv[0] can be a bare name found via PATH; the bundle path is always absolute.
    let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let newData: Data
    let want = SettingsInstaller.merged(old, binary: me, approvalTimeout: timeout)
    if NSDictionary(dictionary: want).isEqual(to: old) { print("Already installed, nothing to change."); exit(0) }
    // Prefer a text patch that leaves the rest of the file untouched; fall back to a full re-render
    // only if the patch can't be applied or doesn't parse to exactly the merged settings.
    if !oldData.isEmpty, let text = String(data: oldData, encoding: .utf8),
       let patched = SettingsInstaller.patched(text, binary: me, approvalTimeout: timeout),
       let obj = (try? JSONSerialization.jsonObject(with: Data(patched.utf8))) as? [String: Any],
       NSDictionary(dictionary: want).isEqual(to: obj) {
        newData = Data(patched.utf8)
    } else {
        do { newData = try SettingsInstaller.render(want) }
        catch { print("error: \(error)"); exit(1) }
    }

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chippy-settings-new.json")
    try? newData.write(to: tmp)
    let diff = Process()
    diff.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    diff.arguments = ["-u", "--label", settingsPath, "--label", "\(settingsPath) (new)",
                      FileManager.default.fileExists(atPath: settingsPath) ? settingsPath : "/dev/null", tmp.path]
    try? diff.run(); diff.waitUntilExit()

    if !yes {
        print("\nWrite these changes? [y/N] ", terminator: "")
        guard let a = readLine(), a.lowercased() == "y" else { print("Aborted. Nothing written."); exit(1) }
    }
    // The file may have changed while the user read the diff: don't clobber edits made meanwhile.
    if ((try? Data(contentsOf: url)) ?? Data()) != oldData {
        print("error: \(settingsPath) changed while waiting, aborting. Run install again."); exit(1)
    }
    if FileManager.default.fileExists(atPath: settingsPath) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = "\(settingsPath).chippy-backup-\(stamp)"
        do { try FileManager.default.copyItem(atPath: settingsPath, toPath: backup) }
        catch { print("error: backup failed (\(error)), not writing"); exit(1) }
        print("Backup: \(backup)")
    } else {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    do { try newData.write(to: url, options: .atomic) } catch { print("error: \(error)"); exit(1) }
    print("Installed. Hook command: \(SettingsInstaller.command(for: me))")
    exit(0)
}

/// `chippy-hook demo approval|queue|question|done`: sends synthetic events so you can see the notch react. Sessions are fake (demo-a/demo-b) and are ended after approvals; the done demo leaves its row until you dismiss.
func demo(_ args: [String]) -> Never {
    let kind = args.first ?? "approval"
    func send(_ o: [String: Any], wait: Bool = false) -> String? {
        guard let fd = SocketClient.connect() else { print("Chippy.app is not running."); exit(1) }
        writeLine(fd: fd, try! JSONSerialization.data(withJSONObject: o))
        guard wait else { close(fd); return nil }
        var tv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        defer { close(fd) }
        return readLine(fd: fd).flatMap { String(data: $0, encoding: .utf8) } ?? "(no answer)"
    }
    func ev(_ sid: String, _ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = ["session_id": sid, "hook_event_name": name, "cwd": "/demo/\(sid == "demo-a" ? "api-server" : "web-app")",
                                "chippy_branch": sid == "demo-a" ? "fix/login-timeout" : "feat/dashboard"]
        for (k, v) in extra { o[k] = v }
        return o
    }
    switch kind {
    case "done":
        _ = send(ev("demo-a", "UserPromptSubmit", ["prompt": "Fix the login timeout bug"]))
        _ = send(ev("demo-a", "PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/demo/api-server/auth.ts", "old_string": "a", "new_string": "a\nb\nc"]]))
        _ = send(ev("demo-a", "Stop", ["last_assistant_message": "Fixed the login timeout: the session cookie was expiring at 5 minutes instead of 30. I changed the TTL in auth.ts and added a test.\n\nShould I also bump the refresh-token lifetime?"]))
        print("Done chip is up and stays until you click Dismiss (or 10 min). Click it for detail.")
    case "question":
        _ = send(ev("demo-a", "UserPromptSubmit", ["prompt": "Set up the login page"]))
        let input: [String: Any] = ["questions": [["question": "Which auth method should the login page use?", "header": "Auth", "multiSelect": false,
            "options": [["label": "Email + password", "description": "Classic form, simplest to ship"],
                        ["label": "Magic link", "description": "No passwords to store"],
                        ["label": "SSO", "description": "Use the school's identity provider"]]]]]
        print("Pick an option on the notch (60s)…")
        print(send(ev("demo-a", "PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": input]), wait: true) ?? "")
        _ = send(ev("demo-a", "SessionEnd"))
    case "approval", "queue":
        _ = send(ev("demo-a", "UserPromptSubmit", ["prompt": "Clean up the build output and reinstall dependencies"]))
        let group = DispatchGroup()
        let reqs: [(String, String)] = kind == "queue"
            ? [("demo-a", "rm -rf node_modules && npm install"), ("demo-b", "git push origin feat/dashboard --force-with-lease")]
            : [("demo-a", "rm -rf node_modules && npm install")]
        for (sid, cmd) in reqs {
            group.enter()
            DispatchQueue.global().async {
                let r = send(ev(sid, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": cmd]]), wait: true)
                print("\(sid): \(r ?? "")"); group.leave()
            }
            Thread.sleep(forTimeInterval: 0.2) // keep arrival order = queue order
        }
        print("Waiting for your answer on the notch (60s)…")
        group.wait()
        for sid in Set(reqs.map { $0.0 }) { _ = send(ev(sid, "SessionEnd")) }
    default:
        print("usage: chippy-hook demo approval|queue|question|done"); exit(2)
    }
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "relay": relay(Array(args.dropFirst()))
case "install": install(Array(args.dropFirst()))
case "demo": demo(Array(args.dropFirst()))
case "stats":
    let events = EventLog.read(ChippyPaths.supportDir.appendingPathComponent("events.jsonl"))
    let w = WaitSummary(events)
    print("approvals: \(w.total)  from notch: \(w.fromNotch)  from terminal: \(w.fromTerminal)  notch share: \(Int((w.notchShare * 100).rounded()))%")
    print("idle wait: total \(w.totalWaitMs)ms  median \(w.medianWaitMs)ms")
    exit(0)
default:
    print("usage: chippy-hook relay | install [--settings PATH] [--yes] [--timeout SECS] | stats")
    exit(args.isEmpty ? 0 : 2)
}
