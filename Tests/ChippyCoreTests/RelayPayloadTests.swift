import XCTest
@testable import ChippyCore

/// #177: the relay sends Chippy only what it reads, and the send has one total deadline.
final class RelayPayloadTests: XCTestCase {
    /// Every key `HookPayload` and `DiffCounts` read, including what the relay adds, plus the big field Chippy never reads.
    private let full: [String: Any] = [
        "session_id": "s", "hook_event_name": "PostToolUse", "cwd": "/w/repo", "tool_name": "MultiEdit",
        "tool_input": ["file_path": "/w/repo/a.swift", "old_string": "a", "new_string": "b", "content": "c",
                       "edits": [["old_string": "x", "new_string": "y"]], "command": "ls"] as [String: Any],
        "prompt": "do it", "last_assistant_message": "done", "transcript_path": "/t.jsonl",
        "chippy_host_pid": 42, "chippy_host_bundle": "com.example.term", "chippy_tty": "/dev/ttys001",
        "chippy_env": ["T3CODE_THREAD_ID": "t"], "chippy_lead_in": "lead", "chippy_branch": "main", "chippy_wait": 60,
        "tool_response": ["content": String(repeating: "x", count: 1000)] as [String: Any],
    ]

    func testTrimRemovesToolResponseAndKeepsEverythingElse() throws {
        let out = RelayPayload.trim(full)
        XCTAssertNil(out["tool_response"])
        XCTAssertEqual(Set(out.keys), Set(full.keys).subtracting(["tool_response"]))
        XCTAssertTrue(NSDictionary(dictionary: out).isEqual(to: full.filter { $0.key != "tool_response" }))
    }

    func testTrimKeepsWhatHookPayloadAndDiffCountsRead() throws {
        let data = try JSONSerialization.data(withJSONObject: RelayPayload.trim(full))
        let p = try XCTUnwrap(HookPayload(json: data))
        XCTAssertEqual(p.sessionId, "s")
        XCTAssertEqual(p.event, "PostToolUse")
        XCTAssertEqual(p.cwd, "/w/repo")
        XCTAssertEqual(p.toolName, "MultiEdit")
        XCTAssertEqual(p.filePath, "/w/repo/a.swift")
        XCTAssertEqual(p.prompt, "do it")
        XCTAssertEqual(p.lastMessage, "done")
        XCTAssertEqual(p.transcriptPath, "/t.jsonl")
        XCTAssertEqual(p.leadIn, "lead")
        XCTAssertEqual(p.branch, "main")
        XCTAssertEqual(p.host?.pid, 42)
        let d = try XCTUnwrap(DiffCounts.forTool("MultiEdit", input: p.toolInput))
        XCTAssertEqual(d.added, 1); XCTAssertEqual(d.removed, 1)
        XCTAssertEqual(try XCTUnwrap(DiffCounts.forTool("Write", input: p.toolInput)).added, 1) // content
        XCTAssertEqual(try XCTUnwrap(DiffCounts.forTool("Edit", input: p.toolInput)).removed, 1) // old_string / new_string
    }

    /// PermissionRequest `tool_input` is out of scope: the Always digest needs all of it.
    func testTrimLeavesToolInputUntouched() {
        let input: [String: Any] = ["command": "rm -rf build", "description": "d", "extra": ["n": 1] as [String: Any]]
        let out = RelayPayload.trim(["hook_event_name": "PermissionRequest", "tool_input": input])
        XCTAssertTrue(NSDictionary(dictionary: out["tool_input"] as! [String: Any]).isEqual(to: input))
    }

    func testTrimWithoutToolResponseIsUnchanged() {
        let small: [String: Any] = ["session_id": "s", "hook_event_name": "Stop"]
        XCTAssertTrue(NSDictionary(dictionary: RelayPayload.trim(small)).isEqual(to: small))
    }

    /// One total deadline for the whole line, not per `write`: a peer that never reads gets 1 MB returned `false` in about the deadline.
    func testSendDeadlineIsTotalNotPerWrite() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let start = Date()
        let ok = writeLine(fd: fds[0], Data(repeating: 0x61, count: 1_000_000), within: RelayPayload.sendDeadline)
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.3)
    }

    func testDeadlineWriteSucceedsWhenPeerReads() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let big = Data(repeating: 0x61, count: 1_000_000)
        let reader = Thread { _ = readLine(fd: fds[1]) }
        reader.start()
        XCTAssertTrue(writeLine(fd: fds[0], big, within: RelayPayload.sendDeadline))
    }
}
