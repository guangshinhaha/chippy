import ChippyCore
import Darwin
import Foundation

// chippy-hook relay                       forward a Claude Code hook event to Chippy.app (fail-open)
// chippy-hook install [--settings P] [--yes]   add hooks to ~/.claude/settings.json (backup + diff + confirm)

func debug(_ s: String) {
    if ProcessInfo.processInfo.environment["CHIPPY_HOOK_DEBUG"] != nil {
        FileHandle.standardError.write(Data("chippy-hook: \(s)\n".utf8))
    }
}

func relay() -> Never {
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
    writeLine(fd: fd, line)
    debug("relayed in \(ms())")
    close(fd)
    exit(0)
}

func install(_ args: [String]) -> Never {
    var settingsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path
    var yes = false
    var i = 0
    while i < args.count {
        if args[i] == "--yes" { yes = true }
        else if args[i] == "--settings", i + 1 < args.count { settingsPath = args[i + 1]; i += 1 }
        i += 1
    }
    let url = URL(fileURLWithPath: settingsPath)
    let oldData = (try? Data(contentsOf: url)) ?? Data()
    let old: [String: Any]
    if oldData.isEmpty { old = [:] }
    else if let o = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any] { old = o }
    else { print("error: \(settingsPath) is not valid JSON, not touching it"); exit(1) }

    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let newData: Data
    do { newData = try SettingsInstaller.render(SettingsInstaller.merged(old, binary: me)) }
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
case "relay": relay()
case "install": install(Array(args.dropFirst()))
default:
    print("usage: chippy-hook relay | install [--settings PATH] [--yes]")
    exit(args.isEmpty ? 0 : 2)
}
