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

    func testSendsTypedTextAsTypedAndRecordsNothingOfIt() throws {
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
        XCTAssertEqual(m.draftTexts(id), ["Q": "half typed"])
        XCTAssertEqual(m.answer(id, selections: [:], texts: m.draftTexts(id)), .sent)
        XCTAssertNotNil(reply(f))
        XCTAssertEqual(m.draftTexts(id), [:])
    }

    func testDraftClearsOnHandBackAndEmptyingAndUnknownIdIsIgnored() {
        let m = model(); let (c, _) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        m.setDraft("nope", question: "Q", text: "x")
        XCTAssertEqual(m.draftTexts("nope"), [:])
        m.setDraft(id, question: "Q", text: "x"); m.setDraft(id, question: "Q", text: "")
        XCTAssertEqual(m.draftTexts(id), [:])
        m.setDraft(id, question: "Q", text: "again")
        m.handBack(id)
        XCTAssertEqual(m.draftTexts(id), [:])
    }

    func testHookGoneWhileTypingIsGoneAndDraftDropped() {
        let m = model(); let (c, f) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        m.setDraft(id, question: "Q", text: "late")
        close(f); fds.removeAll { $0 == f }                    // the hook timed out and hung up
        XCTAssertEqual(m.answer(id, selections: [:], texts: ["Q": "late"]), .gone)
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.draftTexts(id), [:])
    }

    func testReplyFieldFocusFlagResetsWhenNothingIsPending() {
        let m = model(); let (c, _) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        m.setReplyFieldFocused(true, id: id)
        XCTAssertTrue(m.replyFieldFocused)
        m.handBack(id)
        XCTAssertFalse(m.replyFieldFocused)
        XCTAssertNil(m.replyFocusOwner)
    }

    func testFocusPinsFoldTimerAndClearReplyFocusDropsOwner() {
        let m = model(); let (c, _) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        m.setReplyFieldFocused(true, id: id)
        XCTAssertTrue(m.isFoldPinned(id))
        m.clearReplyFocus()
        XCTAssertNil(m.replyFocusOwner)
        XCTAssertFalse(m.replyFieldFocused)
    }

    func testFocusIsFalseWhenAnotherCardTakesTheScreen() {
        let m = model(); let (c, _) = pair(); let (c2, _) = pair()
        m.receiveApproval(qs([mq("Q1")]), c)
        m.receiveApproval(qs([mq("Q2")], session: "s2"), c2)
        let a = m.shownPending!.id
        let b = m.pending.first { $0.id != a }!.id
        m.setReplyFieldFocused(true, id: a)
        XCTAssertTrue(m.replyFieldFocused)
        m.activate(.pending(b)) // card swap while another request stays pending
        XCTAssertFalse(m.replyFieldFocused)
        XCTAssertNil(m.replyFocusOwner)
        m.activate(.pending(a)) // coming back must not resurrect focus
        XCTAssertFalse(m.replyFieldFocused)
        m.setReplyFieldFocused(true, id: b) // a field that is not on screen cannot take focus
        XCTAssertFalse(m.replyFieldFocused)
        m.setReplyFieldFocused(true, id: a)
        m.setReplyFieldFocused(false, id: b) // a stale card's blur does not clear the live one
        XCTAssertTrue(m.replyFieldFocused)
    }

    func testFocusClearsWhenFlagTurnedOffMidEditAndWhenListOpens() {
        let m = model(); let (c, _) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        m.setReplyFieldFocused(true, id: id)
        m.freeTextReplyEnabled = false
        XCTAssertFalse(m.replyFieldFocused)
        XCTAssertNil(m.replyFocusOwner)
        m.freeTextReplyEnabled = true
        XCTAssertFalse(m.replyFieldFocused) // turning it back on does not resurrect focus
        m.setReplyFieldFocused(true, id: id)
        m.openList()
        XCTAssertFalse(m.replyFieldFocused)
        XCTAssertNil(m.replyFocusOwner)
    }

    func testFocusClearsWhenAnswered() {
        let m = model(); let (c, _) = pair()
        m.receiveApproval(qs([mq("Q")]), c)
        let id = m.pending[0].id
        m.setReplyFieldFocused(true, id: id)
        XCTAssertEqual(m.answer(id, selections: [:], texts: ["Q": "hi"]), .sent)
        XCTAssertFalse(m.replyFieldFocused)
        XCTAssertNil(m.replyFocusOwner)
    }

    func testTypedSpacingIsKeptAndLimitUsesTypedLength() {
        XCTAssertEqual(NotchModel.validFreeText("  a  b   c "), "a  b   c")
        XCTAssertEqual(NotchModel.validFreeText("a\tb"), "a b")
        XCTAssertEqual(NotchModel.validFreeText(String(repeating: "x", count: 500)), String(repeating: "x", count: 500))
        XCTAssertNil(NotchModel.validFreeText(String(repeating: "x ", count: 251))) // 501 typed after trim
        XCTAssertNil(NotchModel.validFreeText("x" + String(repeating: "\u{202E}", count: 8100) + "x")) // hidden padding is bounded (16x)
        let q = AskQuestion.parse(["questions": [mq("Q")]])!
        XCTAssertEqual(NotchModel.joined(q, [:], texts: ["Q": "two  spaces"]), ["Q": "two  spaces"])
    }

    func testProblemHintsSayWhatIsWrong() {
        XCTAssertNil(NotchModel.freeTextProblem("fine"))
        XCTAssertTrue(NotchModel.freeTextProblem("   ")!.contains("Type a reply"))
        XCTAssertTrue(NotchModel.freeTextProblem(String(repeating: "x", count: 501))!.contains("Too long"))
        XCTAssertTrue(NotchModel.freeTextProblem("a\nb")!.contains("One line"))
    }

    func testJoinerOnlyRepliesRefusedAndRunsCapped() {
        XCTAssertNil(NotchModel.validFreeText("\u{200D}\u{200C}\u{FE0F}\u{FE0E}"))
        XCTAssertNil(NotchModel.validFreeText(" \u{200D} "))
        XCTAssertEqual(NotchModel.validFreeText("a\u{200D}\u{200D}\u{FE0F}b"), "a\u{200D}b")
        XCTAssertEqual(NotchModel.validFreeText("\u{200D}a"), "a")
        XCTAssertEqual(NotchModel.validFreeText("\u{2764}\u{FE0F}"), "\u{2764}\u{FE0F}")
        XCTAssertEqual(NotchModel.validFreeText("a\u{0B}b\u{0C}c"), "a b c")
    }

    func testManyFamilyEmojiAccepted() {
        let fam = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let s = String(repeating: fam, count: 130)
        XCTAssertEqual(NotchModel.validFreeText(s), s)
        XCTAssertNil(NotchModel.freeTextProblem(s))
        XCTAssertTrue(NotchModel.freeTextProblem(String(repeating: "x", count: 501))!.contains("Too long"))
        XCTAssertTrue(NotchModel.freeTextProblem("x" + String(repeating: "\u{202E}", count: 8100) + "x")!.contains("Too long"))
    }

    func testClearReplyFocusBumpsResetToken() {
        let m = NotchModel()
        let t = m.replyFocusReset
        m.clearReplyFocus()
        XCTAssertNotEqual(m.replyFocusReset, t)
    }
}
