import XCTest
@testable import ChippyCore

private func payload(_ o: [String: Any]) -> HookPayload {
    HookPayload(json: try! JSONSerialization.data(withJSONObject: o))!
}

final class LiveSessionTests: XCTestCase {
    func edit(_ sid: String, file: String, old: String, new: String) -> HookPayload {
        payload(["session_id": sid, "cwd": "/w/proj", "hook_event_name": "PostToolUse", "tool_name": "Edit",
                 "tool_input": ["file_path": file, "old_string": old, "new_string": new]])
    }

    func testEditDiffCountsAndHeadline() {
        var s = SessionStore()
        s.apply(edit("a", file: "/w/proj/Foo.swift", old: "x\ny", new: "x\ny\nz\nw"))
        let r = s.rows[0]
        XCTAssertEqual(r.added, 4); XCTAssertEqual(r.removed, 2)
        XCTAssertEqual(r.detail, "Edited Foo.swift +4 −2")
        XCTAssertEqual(r.headline, "Claude Code · editing 1 file")
        XCTAssertEqual(s.derivedState, .working)
    }

    func testConcurrentSessionsGetSeparateRows() {
        var s = SessionStore()
        s.apply(edit("a", file: "/w/proj/A.swift", old: "", new: "1"))
        s.apply(edit("b", file: "/w/proj/B.swift", old: "", new: "1\n2"))
        XCTAssertEqual(s.rows.count, 2)
        XCTAssertEqual(s.rows.first { $0.id == "a" }?.added, 1)
        XCTAssertEqual(s.rows.first { $0.id == "b" }?.added, 2)
    }

    func testStopThenEnd() {
        var s = SessionStore()
        s.apply(edit("a", file: "/f", old: "", new: "1"))
        s.apply(payload(["session_id": "a", "hook_event_name": "Stop"]))
        XCTAssertEqual(s.derivedState, .done)
        s.apply(payload(["session_id": "a", "hook_event_name": "SessionEnd"]))
        XCTAssertTrue(s.rows.isEmpty); XCTAssertEqual(s.derivedState, .idle)
    }

    func testInstallerIsIdempotentAndPreservesExisting() throws {
        let old: [String: Any] = ["model": "opus", "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo hi"]]]]]]
        let once = SettingsInstaller.merged(old, binary: "/x/chippy-hook")
        let twice = SettingsInstaller.merged(once, binary: "/x/chippy-hook")
        XCTAssertEqual(try SettingsInstaller.render(once), try SettingsInstaller.render(twice))
        XCTAssertEqual(once["model"] as? String, "opus")
        let stop = (once["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2) // user's own hook kept, ours appended
    }

    func testSocketRoundTripAndFailOpen() throws {
        let path = "/tmp/chippy-test-\(getpid()).sock"
        XCTAssertNil(SocketClient.connect(path: path)) // no listener: immediate nil
        let got = expectation(description: "event")
        var received: Data?
        let server = SocketServer(path: path) { line, conn in received = line; conn.respond(nil); got.fulfill() }
        try server.start()
        defer { server.stop() }
        let fd = try XCTUnwrap(SocketClient.connect(path: path))
        writeLine(fd: fd, Data(#"{"session_id":"a","hook_event_name":"Stop"}"#.utf8))
        close(fd)
        wait(for: [got], timeout: 2)
        XCTAssertNotNil(HookPayload(json: try XCTUnwrap(received)))
    }
}
