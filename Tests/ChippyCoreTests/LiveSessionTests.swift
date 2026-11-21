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
        XCTAssertTrue(writeLine(fd: fd, Data(#"{"session_id":"a","hook_event_name":"Stop"}"#.utf8)))
        close(fd)
        wait(for: [got], timeout: 2)
        XCTAssertNotNil(HookPayload(json: try XCTUnwrap(received)))
    }

    /// #175: a peer that never reads must make `writeLine` report failure at the send timeout, not hang or pretend.
    func testWriteLineReportsFailureWhenPeerNeverReads() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        var snd = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fds[0], SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))
        let start = Date()
        let ok = writeLine(fd: fds[0], Data(repeating: 0x61, count: 256 * 1024))
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testWriteLineReportsSuccessWhenPeerReads() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertTrue(writeLine(fd: fds[0], Data("hi".utf8)))
        XCTAssertEqual(readLine(fd: fds[1]), Data("hi".utf8))
    }

    /// #176: a second server must refuse a path a live one owns, and leave it reachable.
    func testSecondServerRefusedWhileFirstIsLive() throws {
        let path = scratchURL("chippy-\(getpid())a.sock").path
        let a = SocketServer(path: path) { _, conn in conn.respond(nil) }
        try a.start()
        defer { a.stop() }
        let b = SocketServer(path: path) { _, conn in conn.respond(nil) }
        XCTAssertThrowsError(try b.start()) { XCTAssertTrue(($0 as? SocketError)?.isAlreadyRunning == true) }
        let fd = try XCTUnwrap(SocketClient.connect(path: path))
        close(fd)
    }

    /// #176: A's stop must not unlink the socket B bound after the file was removed from under A.
    func testStopLeavesSocketBoundByAnotherServer() throws {
        let path = scratchURL("chippy-\(getpid())b.sock").path
        let a = SocketServer(path: path) { _, conn in conn.respond(nil) }
        try a.start()
        unlink(path)
        let b = SocketServer(path: path) { _, conn in conn.respond(nil) }
        try b.start()
        defer { b.stop() }
        a.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let fd = try XCTUnwrap(SocketClient.connect(path: path))
        close(fd)
    }

    /// #176: a stale file with no listener (a crash) is still replaced.
    func testStaleSocketFileIsReplaced() throws {
        let path = scratchURL("chippy-\(getpid())c.sock").path
        let first = SocketServer(path: path) { _, conn in conn.respond(nil) }
        try first.start()
        // Simulate a crash: close the listener without unlinking (stop() would unlink).
        let stale = scratchURL("chippy-\(getpid())c.keep").path
        XCTAssertEqual(rename(path, stale), 0)
        first.stop() // path is gone, so nothing to unlink
        XCTAssertEqual(rename(stale, path), 0) // dead socket file back at the path
        XCTAssertNil(SocketClient.connect(path: path))
        let second = SocketServer(path: path) { _, conn in conn.respond(nil) }
        try second.start()
        defer { second.stop() }
        let fd = try XCTUnwrap(SocketClient.connect(path: path))
        close(fd)
    }
}
