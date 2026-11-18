import Darwin
import XCTest
@testable import ChippyCore

/// #94: typed reply on single-select question cards, behind `freeTextReplyEnabled`.
final class FreeTextReplyTests: XCTestCase {
    private var fds: [Int32] = []
    override func tearDown() { fds.filter { $0 >= 0 }.forEach { close($0) }; fds = [] }

    private func qs(_ list: [[String: Any]], session: String = "s") -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": session, "cwd": "/w/api", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": list]]))!
    }
    private func mq(_ text: String, multi: Bool = false) -> [String: Any] {
        ["question": text, "header": "H", "multiSelect": multi, "options": ["A", "B"].map { ["label": $0, "description": ""] }]
    }
    private func pair() -> (Connection, Int32) {
        var f: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &f), 0)
        fds += f
        return (Connection(fd: f[0]), f[1])
    }
    private func reply(_ fd: Int32) -> [String: Any]? {
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return readLine(fd: fd).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    private var logURL = FileManager.default.temporaryDirectory
    private func model(on: Bool = true) -> NotchModel {
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: logURL))
        m.freeTextReplyEnabled = on
        return m
    }
    private func answers(_ fd: Int32) throws -> [String: String]? {
        let input = try XCTUnwrap(reply(fd)?["updatedInput"] as? [String: Any])
        return input["answers"] as? [String: String]
    }

    func testJoinedAcceptsFreeTextOnSingleSelect() {
        let q = AskQuestion.parse(["questions": [mq("Q")]])!
        XCTAssertEqual(NotchModel.joined(q, [:], texts: ["Q": "  use the staging db  "]), ["Q": "use the staging db"])
        XCTAssertEqual(NotchModel.joined(q, ["Q": ["A"]], texts: ["Q": "mine"]), ["Q": "mine"]) // text replaces the selection
    }

    func testJoinedRefusesMultiSelectEmptyWhitespaceOverLengthAndNewline() {
        let single = AskQuestion.parse(["questions": [mq("Q")]])!
        let multi = AskQuestion.parse(["questions": [mq("Q", multi: true)]])!
        XCTAssertNil(NotchModel.joined(multi, ["Q": ["A"]], texts: ["Q": "typed"]))
        for bad in ["", "   ", "\u{200B}\u{202E}", String(repeating: "x", count: 501), "a\nb", "a\rb", "a\u{2028}b"] {
            XCTAssertNil(NotchModel.joined(single, ["Q": ["A"]], texts: ["Q": bad]), "\(bad.debugDescription)")
        }
        XCTAssertNotNil(NotchModel.joined(single, [:], texts: ["Q": String(repeating: "x", count: 500)]))
    }

    func testHiddenScalarsAreStrippedFromTheSentText() {
        XCTAssertEqual(NotchModel.validFreeText("ab\u{202E}c\u{200B}d"), "abcd")
    }

    func testSendsTypedTextVerbatimAndRecordsNothingOfIt() throws {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(qs([mq("Which?")]), c)
        let secret = "topsecretNRIC S1234567D"
        XCTAssertEqual(m.answer(m.pending[0].id, selections: [:], texts: ["Which?": secret]), .sent)
        XCTAssertEqual(try answers(f), ["Which?": secret])
        XCTAssertTrue(m.pending.isEmpty)
        let log = try String(contentsOf: logURL)
        XCTAssertTrue(log.contains("answered"))
        for part in ["topsecret", "NRIC", "S1234567D", "Which?"] { XCTAssertFalse(log.contains(part), part) }
        XCTAssertFalse(log.contains("\"text\"")); XCTAssertFalse(log.contains("length"))
    }

    func testInvalidTextIsRefusedAndTheCardStays() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        XCTAssertEqual(m.answer(id, selections: [:], texts: ["Q": String(repeating: "y", count: 501)]), .refused)
        XCTAssertEqual(m.answer(id, selections: ["Q": ["A"]], texts: ["Q": "two\nlines"]), .refused)
        XCTAssertEqual(m.pending.count, 1)
        m.handBack(id) // the "Answer in terminal" path
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertNil(reply(f)) // nothing was ever written
    }

    func testFlagOffIgnoresTexts() throws {
        let m = model(on: false); let (c, f) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        XCTAssertEqual(m.answer(m.pending[0].id, selections: [:], texts: ["Q": "hi"]), .refused) // no selection: today's behaviour
        XCTAssertEqual(m.answer(m.pending[0].id, selections: ["Q": ["B"]], texts: ["Q": "hi"]), .sent)
        XCTAssertEqual(try answers(f), ["Q": "B"]) // the selection went, not the text
    }

    func testDraftSurvivesRefreshNewerQuestionAndFoldThenVanishesAfterSend() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        m.setDraft(id, question: "Q", text: "half typed")
        let (c2, _) = pair()
        m.receiveApproval(qs([mq("Other")], session: "s2"), c2) // a newer question arrives
        m.sweep()                                              // refresh
        XCTAssertEqual(m.draft(id, question: "Q"), "half typed")
        XCTAssertEqual(m.draftTexts(id), ["Q": "half typed"])
        XCTAssertEqual(m.answer(id, selections: [:], texts: m.draftTexts(id)), .sent)
        XCTAssertNotNil(reply(f))
        XCTAssertEqual(m.draft(id, question: "Q"), "")
    }

    func testDraftClearsOnHandBackAndEmptyingAndUnknownIdIsIgnored() {
        let m = model(); let (c, _) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        m.setDraft("nope", question: "Q", text: "x")
        XCTAssertEqual(m.draft("nope", question: "Q"), "")
        m.setDraft(id, question: "Q", text: "x"); m.setDraft(id, question: "Q", text: "")
        XCTAssertEqual(m.draftTexts(id), [:])
        m.setDraft(id, question: "Q", text: "again")
        m.handBack(id)
        XCTAssertEqual(m.draft(id, question: "Q"), "")
    }

    func testHookGoneWhileTypingIsGoneAndDraftDropped() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        m.setDraft(id, question: "Q", text: "late")
        close(f); fds.removeAll { $0 == f }                    // the hook timed out and hung up
        XCTAssertEqual(m.answer(id, selections: [:], texts: ["Q": "late"]), .gone)
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.draft(id, question: "Q"), "")
    }

    func testReplyFieldFocusFlagResetsWhenNothingIsPending() {
        let m = model(); let (c, _) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        m.setReplyFieldFocused(true)
        XCTAssertTrue(m.replyFieldFocused)
        m.handBack(m.pending[0].id)
        XCTAssertFalse(m.replyFieldFocused)
    }
}
