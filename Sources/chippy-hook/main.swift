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
        && dict?["tool_name"] as? String != "AskUserQuestion"
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
    do { newData = try SettingsInstaller.render(SettingsInstaller.merged(old, binary: me, approvalTimeout: timeout)) }
    catch { print("error: \(error)"); exit(1) }
    if newData == oldData { print("Already installed, nothing to change."); exit(0) }

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

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "relay": relay(Array(args.dropFirst()))
case "install": install(Array(args.dropFirst()))
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
