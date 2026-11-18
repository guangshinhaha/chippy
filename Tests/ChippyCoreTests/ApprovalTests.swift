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
        XCTAssertTrue(m.visible)                          // an approval is what brings the notch up
        m.resolve(m.pending[0].id, .allow)
        XCTAssertFalse(m.visible)                         // and answering it sends the notch away again
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

    func question() -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s", "cwd": "/w/api", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which?", "header": "H", "multiSelect": false,
                                          "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]]]]]))!
    }

    func multiPayload(_ qs: [[String: Any]]) -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s", "cwd": "/w/api", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": qs]]))!
    }
    func mq(_ text: String, multi: Bool, _ labels: [String] = ["A", "B", "C"]) -> [String: Any] {
        ["question": text, "header": "H", "multiSelect": multi, "options": labels.map { ["label": $0, "description": ""] }]
    }

    func testParseAcceptsMultiSelectAndMixedSets() throws {
        let one = try XCTUnwrap(AskQuestion.parse(["questions": [mq("Q1", multi: true)]]))
        XCTAssertEqual(one.map(\.multiSelect), [true])
        let mixed = try XCTUnwrap(AskQuestion.parse(["questions": [mq("Q1", multi: false), mq("Q2", multi: true)]]))
        XCTAssertEqual(mixed.map(\.multiSelect), [false, true])
    }

    func testParseStillRejectsUnsupportedShapes() {
        XCTAssertNil(AskQuestion.parse(["questions": [mq("Q", multi: true, [])]]))          // no options
        XCTAssertNil(AskQuestion.parse(["questions": [mq("Q", multi: true, ["A", "A"])]])) // duplicate labels
        XCTAssertNil(AskQuestion.parse(["questions": [mq("Q", multi: true), mq("Q", multi: false)]])) // duplicate text
    }

    func testMalformedMultiSelectFallsBackToTheTerminal() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(multiPayload([mq("Q", multi: true, [])]), c)
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertNil(reply(f))                            // closed, no decision written
    }

    func testMultiSelectAnswerJoinsInOptionOrder() throws {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(multiPayload([mq("Q", multi: true)]), c)
        XCTAssertEqual(m.pending.count, 1)
        m.answer(m.pending[0].id, selections: ["Q": ["C", "A"]]) // set order is irrelevant
        let input = try XCTUnwrap(reply(f)?["updatedInput"] as? [String: Any])
        XCTAssertEqual((input["answers"] as? [String: String])?["Q"], "A, C")
        XCTAssertNotNil(input["questions"])
    }

    func testMixedSetAnswersEachInItsOwnFormat() throws {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(multiPayload([mq("S", multi: false), mq("M", multi: true)]), c)
        m.answer(m.pending[0].id, selections: ["S": ["B"], "M": ["B", "A"]])
        let input = try XCTUnwrap(reply(f)?["updatedInput"] as? [String: Any])
        XCTAssertEqual(input["answers"] as? [String: String], ["S": "B", "M": "A, B"])
    }

    func testEmptyOrOversizedSelectionIsRejected() {
        for sel: [String: Set<String>] in [["M": []], ["M": ["nope"]], ["S": ["A", "B"], "M": ["A"]], ["M": ["A"]]] {
            let m = model(); let (c, f) = pair()
            m.receiveApproval(multiPayload([mq("S", multi: false), mq("M", multi: true)]), c)
            m.answer(m.pending[0].id, selections: sel)
            XCTAssertNil(reply(f))                        // nothing written
            XCTAssertEqual(m.pending.count, 1)            // card stays up
        }
    }

    func testSingleSelectQuestionIsAnsweredFromTheNotch() throws {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(question(), c)
        XCTAssertEqual(m.pending.first?.questions?.first?.options.map(\.label), ["A", "B"])
        m.resolve(m.pending[0].id, .allow)                // Allow/Deny must not answer a question
        XCTAssertEqual(m.pending.count, 1)
        m.answer(m.pending[0].id, selections: ["Which?": ["B"]])
        let r = try XCTUnwrap(reply(f))
        XCTAssertEqual(r["behavior"] as? String, "allow")
        let input = try XCTUnwrap(r["updatedInput"] as? [String: Any])
        XCTAssertEqual((input["answers"] as? [String: String])?["Which?"], "B")
        XCTAssertNotNil(input["questions"])               // original questions preserved
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testIncompleteOrUnknownAnswerIsNotSentAndKeepsTheCard() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(question(), c)
        XCTAssertEqual(m.answer(m.pending[0].id, selections: ["Which?": ["not an option"]]), .refused)
        XCTAssertNil(reply(f))                            // nothing written
        XCTAssertEqual(m.pending.count, 1)                // card stays up, no silent loss
        XCTAssertEqual(m.answer(m.pending[0].id, selections: ["Which?": ["A"]]), .sent) // and can still be answered
        XCTAssertNotNil(reply(f))
    }

    func testMultiSelectLabelContainingCommaSpaceStaysInTheTerminal() {
        XCTAssertNil(AskQuestion.parse(["questions": [mq("Q", multi: true, ["Tests, lint", "B"])]]))
        XCTAssertNil(AskQuestion.parse(["questions": [mq("Q", multi: true, ["Tests,lint", "B"])]]))
        XCTAssertNil(AskQuestion.parse(["questions": [mq("Q", multi: true, [" ", "B"])]]))
        XCTAssertNotNil(AskQuestion.parse(["questions": [mq("Q", multi: false, ["Tests, lint", "B"])]])) // single-select is unambiguous
        let m = model(); let (c, f) = pair()
        m.receiveApproval(multiPayload([mq("Q", multi: true, ["Tests, lint", "B"])]), c)
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertNil(reply(f))
    }

    func testDuplicateQuestionTextStaysInTheTerminal() {
        let q: [String: Any] = ["question": "Which?", "header": "H", "multiSelect": false, "options": [["label": "A", "description": ""]]]
        let p = HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s", "cwd": "/w", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [q, q]]]))!
        let m = model(); let (c, _) = pair()
        m.receiveApproval(p, c)
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testSweepDropsRequestWhenHookGivesUp() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(payload(), c)
        close(f)                                          // hook timed out / terminal answered
        m.sweep()
        XCTAssertTrue(m.pending.isEmpty); XCTAssertTrue(m.terminalItems.isEmpty) // #42: gone inside the window = answered in terminal, no chip
    }

    func testAnswerAfterHookGaveUpReportsGone() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(question(), c)
        close(f)
        XCTAssertEqual(m.answer(m.pending[0].id, selections: ["Which?": ["A"]]), .gone)
        XCTAssertTrue(m.pending.isEmpty)
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
