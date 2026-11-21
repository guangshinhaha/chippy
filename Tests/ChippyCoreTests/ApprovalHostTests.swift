import Darwin
import XCTest
@testable import ChippyCore

/// Issue #164: an approval from a session Chippy has not heard from yet still knows its host app, so the mute rule and
/// "Open terminal" work for sessions that were already running before Chippy launched.
final class ApprovalHostTests: XCTestCase {
    func event(_ name: String, host: (pid: Int, bundle: String)? = nil, session: String = "s") -> HookPayload {
        var o: [String: Any] = ["session_id": session, "cwd": "/w/api", "hook_event_name": name]
        if name == "PermissionRequest" { o["tool_name"] = "Bash"; o["tool_input"] = ["command": "ls"] }
        if name == "PostToolUse" { o["tool_name"] = "Read"; o["tool_input"] = ["file_path": "/w/api/a.swift"] }
        if let h = host { o["chippy_host_pid"] = h.pid; o["chippy_host_bundle"] = h.bundle; o["chippy_tty"] = "ttys004" }
        return HookPayload(json: try! JSONSerialization.data(withJSONObject: o))!
    }

    func pair() -> Connection {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return Connection(fd: fds[0])
    }

    func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: scratchURL("always-\(UUID()).json")),
                   log: EventLog(url: scratchURL("ev-\(UUID()).jsonl")))
    }

    let terminal = (pid: 4242, bundle: "com.apple.Terminal")
    let t3 = (pid: 5151, bundle: "com.t3tools.t3code")

    func testTheEventsThatCarryAHostIncludePermissionRequest() {
        for e in ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest"] {
            XCTAssertTrue(HostFields.events.contains(e), e)
        }
        XCTAssertFalse(HostFields.events.contains("PostToolUse"), "tool events stay as they are: no host lookup per tool call")
    }

    func testAnApprovalFillsTheHostOnASessionThatHasNone() {
        let m = model()
        m.apply(event("PostToolUse")) // a session Chippy only knows from a tool event: no host yet
        XCTAssertNil(m.sessions.first?.host)
        m.receiveApproval(event("PermissionRequest", host: terminal), pair())
        XCTAssertEqual(m.sessions.first?.host?.bundle, "com.apple.Terminal")
        XCTAssertEqual(m.sessions.first?.host?.tty, "ttys004")
    }

    func testAnApprovalNeverReplacesAKnownHost() {
        let m = model()
        m.apply(event("UserPromptSubmit", host: terminal))
        m.receiveApproval(event("PermissionRequest", host: t3), pair())
        XCTAssertEqual(m.sessions.first?.host?.bundle, "com.apple.Terminal")
    }

    func testAnApprovalWithNoHostLeavesTheSessionAlone() {
        let m = model()
        m.apply(event("PostToolUse"))
        m.receiveApproval(event("PermissionRequest"), pair())
        XCTAssertNil(m.sessions.first?.host)
    }

    func testTheApprovalSoundGetsTheHostOfASessionWithNone() {
        let m = model()
        var heard: [HostInfo?] = []
        m.onSound = { kind, _, host, _ in if kind == .needsYou { heard.append(host) } }
        m.apply(event("PostToolUse"))
        m.receiveApproval(event("PermissionRequest", host: t3), pair())
        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard.first??.bundle, "com.t3tools.t3code", "with that host in front the policy mutes it (#143)")
    }

    func testTheCardOfAnUnseenSessionOpensItsHost() {
        let m = model()
        m.receiveApproval(event("PermissionRequest", host: terminal, session: "fresh"), pair())
        XCTAssertEqual(m.host(for: m.pending[0])?.bundle, "com.apple.Terminal")
    }
}
