import XCTest
@testable import ChippyCore

final class SummaryCleanerTests: XCTestCase {
    func testPlainPromptUnchanged() { XCTAssertEqual(SummaryCleaner.cleanPrompt("Fix the  login\nbug"), "Fix the login bug") }
    func testNilAndEmpty() {
        XCTAssertNil(SummaryCleaner.cleanPrompt(nil))
        XCTAssertNil(SummaryCleaner.cleanPrompt("  \n "))
    }
    func testTaskNotificationOnlyIsSkipped() {
        XCTAssertNil(SummaryCleaner.cleanPrompt("<task-notification><task-id>b1</task-id><summary>done</summary></task-notification>"))
    }
    func testNotificationPlusRealText() {
        XCTAssertEqual(SummaryCleaner.cleanPrompt("<task-notification>\n<task-id>b1</task-id>\n</task-notification>\nFix it"), "Fix it")
    }
    func testStrayHyphenTagsStrippedContentKept() {
        XCTAssertEqual(SummaryCleaner.cleanPrompt("see <task-id>abc</task-id> now"), "see abc now")
    }
    func testPlainAngleTextKept() {
        XCTAssertEqual(SummaryCleaner.cleanPrompt("is a < b and <div> ok"), "is a < b and <div> ok")
    }
    func testUnclosedBlockDoesNotEatProse() {
        XCTAssertEqual(SummaryCleaner.cleanPrompt("<system-reminder> hello"), "hello")
    }
    func testNestedAndCaseInsensitive() {
        XCTAssertNil(SummaryCleaner.cleanPrompt("<SYSTEM-REMINDER>a<system-reminder>b</system-reminder></SYSTEM-REMINDER>"))
    }
    func testHugeAdversarialInputIsFast() {
        let s = String(repeating: "<task-notification>", count: 50_000)
        let t = Date()
        _ = SummaryCleaner.cleanPrompt(s)
        XCTAssertLessThan(Date().timeIntervalSince(t), 2)
    }

    func testDecisionBasic() {
        XCTAssertEqual(SummaryCleaner.closingDecision("Done.\n\nShould I also bump the refresh-token lifetime, or leave it at 7 days?"),
                       "Should I also bump the refresh-token lifetime, or leave it at 7 days?")
    }
    func testDecisionLastSentenceOfParagraph() {
        XCTAssertEqual(SummaryCleaner.closingDecision("I fixed it. Want me to add a test?"), "Want me to add a test?")
    }
    func testDecisionStripsMarkdown() {
        XCTAssertEqual(SummaryCleaner.closingDecision("Ok.\n**Ship it with `--force`?**"), "Ship it with --force?")
    }
    func testNoQuestionIsNil() {
        XCTAssertNil(SummaryCleaner.closingDecision("All done."))
        XCTAssertNil(SummaryCleaner.closingDecision("Why? Because it works."))
        XCTAssertNil(SummaryCleaner.closingDecision(nil))
        XCTAssertNil(SummaryCleaner.closingDecision(""))
    }
    func testQuestionInsideCodeFenceIsNil() {
        XCTAssertNil(SummaryCleaner.closingDecision("Run:\n```\nwhat is this?"))
    }
    func testUrlTailIsNil() { XCTAssertNil(SummaryCleaner.closingDecision("See https://example.com/page?")) }
    func testBareQuestionMarkIsNil() {
        XCTAssertNil(SummaryCleaner.closingDecision("?"))
        XCTAssertNil(SummaryCleaner.closingDecision("Ok. ??"))
    }
    func testLongQuestionCapped() {
        let q = String(repeating: "really ", count: 100) + "sure?"
        XCTAssertLessThanOrEqual(SummaryCleaner.closingDecision(q)?.count ?? 999, SummaryCleaner.maxDecisionChars)
    }
    func testHugeReplyIsFast() {
        let s = String(repeating: "a. ", count: 100_000) + "ok?"
        XCTAssertEqual(SummaryCleaner.closingDecision(s), "ok?")
    }
    func testDoneItemWiring() {
        let d = DoneItem(sessionId: "s", project: "p", branch: nil, files: 0, added: 0, removed: 0, reply: "Done. Merge it?", prompt: "<task-id>x</task-id>", at: Date())
        XCTAssertEqual(d.decision, "Merge it?")
        XCTAssertEqual(d.cleanPrompt, "x")
    }
}
