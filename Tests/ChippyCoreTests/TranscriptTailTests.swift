import Darwin
import XCTest
@testable import ChippyCore

/// Issue #48: question cards show Claude's lead-in, read from the transcript tail. All sample text is synthetic.
final class TranscriptTailTests: XCTestCase {
    private func asst(_ blocks: [[String: Any]]) -> String { line(["type": "assistant", "message": ["content": blocks]]) }
    private func text(_ t: String) -> [String: Any] { ["type": "text", "text": t] }
    private func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
    private func parse(_ lines: [String], mid: Bool = false, max: Int = 600) -> String? {
        TranscriptTail.lastAssistantText(inTail: Data((lines.joined(separator: "\n") + "\n").utf8), startsMidFile: mid, maxChars: max)
    }
    private func tmp(_ content: String) -> String {
        let p = NSTemporaryDirectory() + "chippy-tt-\(UUID().uuidString).jsonl"
        try! content.write(toFile: p, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: p) }
        return p
    }

    func testLastAssistantTextWins() {
        XCTAssertEqual(parse([asst([text("first")]), asst([text("second")]), asst([["type": "tool_use", "name": "AskUserQuestion"]])]), "second")
    }

    func testLastTextBlockInALine() {
        XCTAssertEqual(parse([asst([text("a"), ["type": "thinking"], text("b")])]), "b")
    }

    func testEmptyAndMissingFile() {
        XCTAssertNil(parse([]))
        XCTAssertNil(TranscriptTail.leadIn(path: tmp("")))
        XCTAssertNil(TranscriptTail.leadIn(path: "/nonexistent/x.jsonl"))
        XCTAssertNil(TranscriptTail.leadIn(path: "relative.jsonl"))
    }

    func testNoAssistantMessage() {
        XCTAssertNil(parse([line(["type": "user", "message": ["content": "hi"]]), line(["type": "queue-operation"])]))
    }

    func testMalformedLinesSkipped() {
        XCTAssertEqual(parse([asst([text("ok")]), "{not json", "", "[1,2]", line(["type": "assistant"])]), "ok")
    }

    func testToolResultsOrARealPromptMakeEarlierTextStale() {
        let toolResult = line(["type": "user", "message": ["content": [["type": "tool_result", "content": "x"]]]])
        XCTAssertEqual(parse([asst([text("lead")]), asst([["type": "tool_use"]])]), "lead") // the ask itself follows the lead-in
        XCTAssertNil(parse([asst([text("Let me read the config")]), asst([["type": "tool_use"]]), toolResult, asst([["type": "tool_use"]])]))
        let prompt = line(["type": "user", "message": ["content": "new prompt"]])
        XCTAssertNil(parse([asst([text("stale, from a previous turn")]), prompt, asst([["type": "tool_use"]])]))
    }

    func testSidechainAndBlankTextIgnored() {
        let side = line(["type": "assistant", "isSidechain": true, "message": ["content": [text("subagent chatter")]]])
        XCTAssertEqual(parse([asst([text("main")]), side, asst([text("  \n ")])]), "main")
    }

    func testHugeFileOnlyReadsTail() {
        // About 2 MB of filler after a head line that must never be reached.
        let filler = asst([text(String(repeating: "x", count: 1000))])
        var s = asst([text("HEAD")]) + "\n"
        for _ in 0..<2000 { s += filler + "\n" }
        s += asst([text("tail text")]) + "\n"
        XCTAssertEqual(TranscriptTail.leadIn(path: tmp(s)), "tail text")
        // Only non-message lines in the last 64 KB: the head is out of reach, so nothing is found.
        let onlyOld = asst([text("HEAD")]) + "\n" + String(repeating: line(["type": "attachment", "message": [:]]) + "\n", count: 3000)
        XCTAssertNil(TranscriptTail.leadIn(path: tmp(onlyOld)))
    }

    func testPartialFirstLineOfTailDropped() {
        XCTAssertNil(parse(["ssistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"cut\"}]}}"], mid: true))
    }

    func testTruncationCapsAtLimitWithEllipsis() {
        XCTAssertEqual(TranscriptTail.truncate("short", to: 600), "short")
        let cut = TranscriptTail.truncate(String(repeating: "a", count: 700), to: 600)
        XCTAssertEqual(cut.count, 600)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertEqual(parse([asst([text(String(repeating: "b", count: 900))])])?.count, 600)
        XCTAssertEqual(TranscriptTail.truncate("héllo wörld 👩‍💻 ok", to: 8).count, 8)
    }

    private func questionPayload(_ tool: String) -> Data {
        let o: [String: Any] = ["session_id": "real", "hook_event_name": "PermissionRequest", "cwd": "/w/x", "tool_name": tool,
            "chippy_lead_in": "SECRET-LEAD-IN", "tool_input": ["questions": [["question": "A or B?", "multiSelect": false, "options": [["label": "A"], ["label": "B"]]]]]]
        return try! JSONSerialization.data(withJSONObject: o)
    }

    func testLeadInReachesTheQuestionRequestOnly() {
        XCTAssertEqual(PendingRequest(payload: HookPayload(json: questionPayload("AskUserQuestion"))!).leadIn, "SECRET-LEAD-IN")
        XCTAssertNil(PendingRequest(payload: HookPayload(json: questionPayload("Bash"))!).leadIn)
    }

    func testLeadInIsNeverWrittenToTheEventLog() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "chippy-ev-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: url))
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        m.receiveApproval(HookPayload(json: questionPayload("AskUserQuestion"))!, Connection(fd: fds[0]))
        XCTAssertEqual(m.pending.first?.leadIn, "SECRET-LEAD-IN")
        m.answer(m.pending[0].id, ["A or B?": "A"])
        let logged = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertFalse(logged.isEmpty)
        XCTAssertFalse(logged.contains("SECRET-LEAD-IN"))
        close(fds[1])
    }
}
