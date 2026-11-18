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
    func testUnclosedBlockIsDroppedEntirely() {
        XCTAssertNil(SummaryCleaner.cleanPrompt("<system-reminder> hello"))
        XCTAssertEqual(SummaryCleaner.cleanPrompt("Fix it <task-notification><task-id>b1</task-id> still going"), "Fix it")
    }
    func testArbitraryHyphenTagsKept() {
        XCTAssertEqual(SummaryCleaner.cleanPrompt("Fix the <my-component> bug"), "Fix the <my-component> bug")
    }
    func testLongBlockCleanedBeforeTruncation() {
        let block = "<task-notification><summary>" + String(repeating: "secret ", count: 60) + "</summary></task-notification>"
        let p = HookPayload(json: Data((#"{"session_id":"s","hook_event_name":"UserPromptSubmit","cwd":"/a","prompt":"\#(block) Fix it"}"#).utf8))!
        var store = SessionStore()
        store.apply(p)
        XCTAssertEqual(store.rows.first?.lastPrompt, "Fix it")
    }
    func testAsksYouAndDecisionAgree() {
        for r in ["Merge it?**", "(Merge it?)", "Merge it?)", "**Merge it?**"] {
            let d = DoneItem(sessionId: "s", project: "p", branch: nil, files: 0, added: 0, removed: 0, reply: "Done. " + r, prompt: nil, at: Date())
            XCTAssertTrue(d.asksYou, r)
            XCTAssertEqual(d.decision, "Merge it?", r)
            XCTAssertEqual(d.replyWithoutDecision, "Done.", r)
        }
    }
    func testDecisionTrimmedFromReply() {
        let d = DoneItem(sessionId: "s", project: "p", branch: nil, files: 0, added: 0, removed: 0, reply: "Fixed it.\n\nShip it?", prompt: nil, at: Date())
        XCTAssertEqual(d.replyWithoutDecision, "Fixed it.")
    }
    func testAbbreviationsDoNotSplitButNumbersAndNoDo() {
        XCTAssertEqual(SummaryCleaner.closingDecision("Done. Should I use a cache, e.g. Redis, or Mr. Smith's way?"),
                       "Should I use a cache, e.g. Redis, or Mr. Smith's way?")
        XCTAssertEqual(SummaryCleaner.closingDecision("Add tests, docs, etc. Should I proceed?"), "Add tests, docs, etc. Should I proceed?")
        XCTAssertEqual(SummaryCleaner.closingDecision("The build was no. Want me to retry?"), "Want me to retry?")
        XCTAssertEqual(SummaryCleaner.closingDecision("Tried v2. Want me to retry?"), "Want me to retry?")
        XCTAssertEqual(SummaryCleaner.closingDecision("Done. Bump to 1.5 or keep it?"), "Bump to 1.5 or keep it?")
    }
    func testFenceParityOverWholeText() {
        let big = "```\ncode\n```\n" + String(repeating: "x. ", count: 3000) + "Go on?"
        XCTAssertEqual(SummaryCleaner.closingDecision(big), "Go on?")
        let open = "```\ncode " + String(repeating: "x. ", count: 3000) + "Go on?"
        XCTAssertNil(SummaryCleaner.closingDecision(open))
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
        let s = String(repeating: "a. ", count: 100_000) + "go on?"
        XCTAssertEqual(SummaryCleaner.closingDecision(s), "go on?")
    }
    func testDoneItemWiring() {
        let d = DoneItem(sessionId: "s", project: "p", branch: nil, files: 0, added: 0, removed: 0, reply: "Done. Merge it?", prompt: "<task-id>x</task-id>", at: Date())
        XCTAssertEqual(d.decision, "Merge it?")
        XCTAssertEqual(SummaryCleaner.cleanPrompt(d.prompt), "x")
    }
    func testPreviousPromptKeptWhenNewOneIsAllMarkup() {
        func send(_ prompt: String) -> HookPayload {
            HookPayload(json: Data((#"{"session_id":"s","hook_event_name":"UserPromptSubmit","cwd":"/a","prompt":"\#(prompt)"}"#).utf8))!
        }
        var store = SessionStore()
        store.apply(send("Real task"))
        store.apply(send("<task-notification>x</task-notification>"))
        XCTAssertEqual(store.rows.first?.lastPrompt, "Real task")
    }
    func testCleanThenCapNotCapThenClean() {
        let s = String(repeating: "a ", count: 3000) + "<task-notification>z</task-notification> tail"
        XCTAssertTrue(SummaryCleaner.cleanPrompt(s)?.hasSuffix("tail") ?? false)
    }
    func testManyUnclosedTagsFast() {
        let s = String(repeating: "x <command-name> ", count: 6000)
        let t = Date()
        XCTAssertEqual(SummaryCleaner.cleanPrompt(s), "x")
        XCTAssertLessThan(Date().timeIntervalSince(t), 2)
        let closedMix = String(repeating: "<system-reminder>a</system-reminder> y ", count: 2500)
        XCTAssertLessThan(SummaryCleaner.cleanPrompt(closedMix)?.count ?? 0, 6000)
    }
    func testTruncatedDecisionKeepsFullSentenceInBody() {
        let q = String(repeating: "really ", count: 100) + "sure?"
        let d = DoneItem(sessionId: "s", project: "p", branch: nil, files: 0, added: 0, removed: 0, reply: "Done.\n" + q, prompt: nil, at: Date())
        XCTAssertNotNil(d.decision)
        XCTAssertTrue(d.replyWithoutDecision.hasSuffix("sure?"))
    }
}
