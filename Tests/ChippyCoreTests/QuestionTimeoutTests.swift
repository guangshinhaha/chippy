import Darwin
import XCTest
@testable import ChippyCore

/// Issue #34: questions wait longer than approvals; installs upgrade in place; "Answer in terminal" hands back.
final class QuestionTimeoutTests: XCTestCase {
    private let bin = "/App/chippy-hook"
    private let oldCmd = "\"/App/chippy-hook\" relay --timeout 20"

    private func permissionEntries(_ s: [String: Any]) -> [[String: Any]] {
        (s["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]]
    }

    private func same(_ a: Any, _ b: Any) -> Bool { NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b]) }

    func testFreshInstallWritesBothFlagsAndTimeout130() {
        let out = SettingsInstaller.merged([:], binary: bin)
        let hook = (permissionEntries(out)[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(hook["command"] as? String, "\"/App/chippy-hook\" relay --timeout 60 --question-timeout 120")
        XCTAssertEqual(hook["timeout"] as? Int, 130)
        XCTAssertTrue(NSDictionary(dictionary: SettingsInstaller.merged(out, binary: bin)).isEqual(to: out)) // "Already installed"
    }

    func testUpgradeRewritesOnlyChippyPermissionHook() {
        let theirs: [String: Any] = ["type": "command", "command": "/usr/local/bin/audit", "timeout": 5]
        let other: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "echo hi"]]]
        let stop: [[String: Any]] = [["matcher": "*", "hooks": [["type": "command", "command": "\"/App/chippy-hook\" relay"]]]]
        let old: [String: Any] = ["model": "x", "hooks": [
            "PermissionRequest": [["matcher": "*", "hooks": [theirs, ["type": "command", "command": oldCmd, "timeout": 30]]], other],
            "Stop": stop,
            "PreToolUse": [other]]]
        let events = ["PermissionRequest", "Stop"]
        let up = SettingsInstaller.merged(old, binary: bin, events: events)
        let entries = permissionEntries(up)
        let hooks = entries[0]["hooks"] as! [[String: Any]]
        XCTAssertTrue(same(hooks[0], theirs))                                          // their hook in the same array: untouched
        XCTAssertEqual(hooks[1]["command"] as? String, SettingsInstaller.command(for: bin, approvalTimeout: 60, questionTimeout: 120))
        XCTAssertEqual(hooks[1]["timeout"] as? Int, 130)
        XCTAssertTrue(same(entries[1], other))                                         // their other entry: untouched
        let h = up["hooks"] as! [String: Any]
        XCTAssertTrue(same(h["Stop"]!, stop))                                          // other chippy events: unchanged
        XCTAssertTrue(same(h["PreToolUse"]!, [other]))
        XCTAssertEqual(up["model"] as? String, "x")
        XCTAssertTrue(NSDictionary(dictionary: SettingsInstaller.merged(up, binary: bin, events: events)).isEqual(to: up)) // idempotent
    }

    func testPatchDeclinesAnUpgradeButAcceptsAnUpToDateFile() throws {
        let old = "{\n  \"hooks\": {\n    \"PermissionRequest\": [ { \"matcher\": \"*\", \"hooks\": [ { \"type\": \"command\", \"command\": \"\\\"/App/chippy-hook\\\" relay --timeout 20\", \"timeout\": 30 } ] } ]\n  }\n}\n"
        XCTAssertNil(SettingsInstaller.patched(old, binary: bin, events: ["PermissionRequest"]))
        let fresh = try XCTUnwrap(SettingsInstaller.patched("{\n  \"a\": 1\n}\n", binary: bin, events: ["PermissionRequest"]))
        XCTAssertNotNil(SettingsInstaller.patched(fresh, binary: bin, events: ["PermissionRequest"]))
        XCTAssertTrue(fresh.contains("--question-timeout 120"))
        XCTAssertTrue(fresh.contains("\"timeout\": 130"))
    }

    func testHandBackSendsNothingRemovesRequestAndLogsIt() throws {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")
        let m = NotchModel(always: AlwaysStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("always-\(UUID()).json")),
                           log: EventLog(url: logURL))
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let q: [String: Any] = ["question": "Which?", "header": "H", "multiSelect": false, "options": [["label": "A", "description": ""]]]
        m.receiveApproval(HookPayload(json: try JSONSerialization.data(withJSONObject: [
            "session_id": "s", "cwd": "/w", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [q]]]))!, Connection(fd: fds[0]))
        XCTAssertEqual(m.state, .needsYou)
        m.handBack(m.pending[0].id)
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        XCTAssertNil(readLine(fd: fds[1]))                 // the hook gets EOF and prints nothing
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.state, .idle)
        let ev = EventLog.read(logURL)
        XCTAssertEqual(ev.last?.decision, "handed_back"); XCTAssertEqual(ev.last?.channel, .terminal)
        m.handBack("stale")                                // unknown id is ignored
        close(fds[1])
    }
}
