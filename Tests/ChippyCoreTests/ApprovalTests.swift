import Darwin
import XCTest
@testable import ChippyCore

final class ApprovalTests: XCTestCase {
    func payload(tool: String = "Bash", cmd: String = "npm install", cwd: String = "/w/api") -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s", "cwd": cwd, "hook_event_name": "PermissionRequest",
            "tool_name": tool, "tool_input": ["command": cmd]]))!
    }

    /// A Connection whose far end we can read from.
    func pair() -> (Connection, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (Connection(fd: fds[0]), fds[1])
    }

    func reply(_ fd: Int32) -> [String: Any]? {
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return readLine(fd: fd).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("always-\(UUID()).json")),
                   log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")))
    }

    func testAskIsShownVerbatimAndStateIsNeedsYou() {
        let m = model(); let (c, _) = pair()
        m.receiveApproval(payload(), c)
        XCTAssertEqual(m.pending.first?.ask, "Bash: npm install")
        XCTAssertEqual(m.state, .needsYou)
    }

    func testAllowAndDenyReplyToTheExactRequest() {
        let m = model()
        let (c1, f1) = pair(), (c2, f2) = pair()
        m.receiveApproval(payload(cmd: "npm install"), c1)
        m.receiveApproval(payload(cmd: "rm -rf build"), c2)
        let second = m.pending[1].id
        m.resolve(second, .deny)                          // answer the second, not the first
        XCTAssertEqual(reply(f2)?["behavior"] as? String, "deny")
        XCTAssertEqual(m.pending.count, 1)
        m.resolve(m.pending[0].id, .allow)
        XCTAssertEqual(reply(f1)?["behavior"] as? String, "allow")
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.state, .idle)
    }

    func testStaleIdIsIgnored() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(payload(), c)
        let id = m.pending[0].id
        m.resolve(id, .allow); m.resolve(id, .deny)       // second click on a resolved request
        XCTAssertEqual(reply(f)?["behavior"] as? String, "allow")
        XCTAssertNil(reply(f))                            // nothing more was written
    }

    func testAlwaysSuppressesNextIdenticalPromptOnlyInSameProject() {
        let m = model()
        let (c1, _) = pair()
        m.receiveApproval(payload(), c1)
        m.resolve(m.pending[0].id, .always)
        let (c2, f2) = pair()
        m.receiveApproval(payload(), c2)                  // identical, same project
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(reply(f2)?["behavior"] as? String, "allow")
        let (c3, _) = pair()
        m.receiveApproval(payload(cwd: "/w/other"), c3)   // other project: still asks
        XCTAssertEqual(m.pending.count, 1)
        let (c4, _) = pair()
        m.receiveApproval(payload(cmd: "npm install evil"), c4) // different ask: still asks
        XCTAssertEqual(m.pending.count, 2)
    }

    func testAlwaysSurvivesRestart() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("always-\(UUID()).json")
        let m1 = NotchModel(always: AlwaysStore(url: url), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl"))); let (c, _) = pair()
        m1.receiveApproval(payload(), c); m1.resolve(m1.pending[0].id, .always)
        let m2 = NotchModel(always: AlwaysStore(url: url), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl"))); let (c2, f2) = pair()
        m2.receiveApproval(payload(), c2)
        XCTAssertEqual(reply(f2)?["behavior"] as? String, "allow")
    }

    func testAskUserQuestionIsLeftAlone() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(payload(tool: "AskUserQuestion"), c)
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertNil(reply(f))                            // closed, no decision written
    }

    func testSweepDropsRequestWhenHookGivesUp() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(payload(), c)
        close(f)                                          // hook timed out / terminal answered
        m.sweep()
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.state, .idle)
    }

    func testAlwaysOnAnEditDoesNotCoverOtherContentInTheSameFile() {
        func edit(_ new: String) -> HookPayload {
            HookPayload(json: try! JSONSerialization.data(withJSONObject: [
                "session_id": "s", "cwd": "/w/api", "hook_event_name": "PermissionRequest", "tool_name": "Edit",
                "tool_input": ["file_path": "/w/api/a.swift", "old_string": "x", "new_string": new]]))!
        }
        let m = model()
        let (c1, _) = pair(); m.receiveApproval(edit("safe"), c1); m.resolve(m.pending[0].id, .always)
        let (c2, f2) = pair(); m.receiveApproval(edit("safe"), c2)   // identical content: auto
        XCTAssertEqual(reply(f2)?["behavior"] as? String, "allow")
        let (c3, _) = pair(); m.receiveApproval(edit("rm -rf / # different content"), c3)
        XCTAssertEqual(m.pending.count, 1)                            // different content: still asks
    }

    func testAlwaysFileHoldsNoRawCommandText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("always-\(UUID()).json")
        let m = NotchModel(always: AlwaysStore(url: url), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")))
        let (c, _) = pair(); m.receiveApproval(payload(cmd: "curl -H token=SECRET123 x"), c)
        m.resolve(m.pending[0].id, .always)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("SECRET123")); XCTAssertFalse(text.contains("curl"))
    }

    func testClickAfterHookGaveUpIsNotAnsweredOrRemembered() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(payload(), c)
        let id = m.pending[0].id
        close(f)                                   // hook timed out; sweep hasn't run yet
        m.resolve(id, .always)                     // late click
        XCTAssertTrue(m.pending.isEmpty)
        let (c2, _) = pair(); m.receiveApproval(payload(), c2)
        XCTAssertEqual(m.pending.count, 1)         // Always was NOT stored
    }
}
