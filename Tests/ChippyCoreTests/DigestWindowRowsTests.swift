import XCTest
@testable import ChippyCore

/// Issue #167: the menu bar digest window lists every row of the digest, in the notch's order, and carries no content text.
final class DigestWindowRowsTests: XCTestCase {
    let t0 = Date().addingTimeInterval(-1000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // Fixture with all four kinds of content text: prompt, reply, a question, a command.
    func done(_ sid: String, _ s: TimeInterval, reply: String = "SECRET-REPLY Shall I deploy it?") -> DoneItem {
        DoneItem(sessionId: sid, project: sid, branch: nil, files: 0, added: 0, removed: 0, reply: reply, prompt: "SECRET-PROMPT", at: at(s), cwd: sid)
    }
    func term(_ sid: String, _ s: TimeInterval) -> TerminalItem { TerminalItem(sessionId: sid, project: sid, at: at(s), tool: "SECRET-COMMAND-rm-rf", cwd: sid) }

    func digest() -> AwayDigest.Result {
        let finished = (0..<7).map { done("d\($0)", 10 + TimeInterval($0)) }
        return AwayDigest.build(since: at(0), terminal: [term("t1", 5), term("t0", 3)], done: finished,
                                recent: [RecentItem(sessionId: "r", project: "r", at: at(50))], cap: .max)
    }

    func testTheWindowListsTheSameRowsInTheSameOrderAsTheDigest() {
        let d = digest()
        let rows = DigestWindowRows.rows(from: d)
        XCTAssertEqual(rows.map(\.id), d.rows.map(\.sessionId))
        XCTAssertEqual(rows.map(\.at), d.rows.map(\.at))
        XCTAssertEqual(rows.map(\.target), d.rows.map(\.target))
    }

    func testTheWindowIsNotCappedAtTheNotchsFiveRows() {
        let d = digest()
        XCTAssertGreaterThan(d.rows.count, AwayDigest.maxRows)
        XCTAssertEqual(DigestWindowRows.rows(from: d).count, 10, "2 asks + 7 finished + 1 recent: none behind +N more")
    }

    func testStatusNeedsYouFirstAndARecentOnlyRowHasNoTarget() {
        let rows = DigestWindowRows.rows(from: digest())
        XCTAssertEqual(rows.prefix(2).map(\.needsYou), [true, true])
        XCTAssertEqual(rows.prefix(2).map(\.id), ["t0", "t1"], "oldest ask first, as in the notch")
        XCTAssertEqual(rows.dropFirst(2).map(\.needsYou), Array(repeating: false, count: 8))
        XCTAssertNil(rows.first { $0.id == "r" }?.target, "no Open button for a Recent-only row")
        XCTAssertNotNil(rows.first { $0.id == "d0" }?.target)
        XCTAssertEqual(rows.first { $0.id == "t0" }?.statusText, "asked in terminal")
        XCTAssertEqual(rows.first { $0.id == "d0" }?.statusText, "asks you", "the fixture's reply ends on a question")
    }

    func testNoFieldCarriesPromptReplyQuestionOrCommandText() {
        let d = digest()
        let everything = DigestWindowRows.rows(from: d).map { "\($0)" }.joined() + DigestWindowRows.title(d)
        for secret in ["SECRET-PROMPT", "SECRET-REPLY", "Shall I deploy", "SECRET-COMMAND", "rm-rf"] {
            XCTAssertFalse(everything.contains(secret), secret)
        }
    }

    func testNoDigestMeansNoRows() {
        XCTAssertEqual(DigestWindowRows.rows(from: nil), [])
        XCTAssertEqual(DigestWindowRows.title(nil), "Nothing to report")
    }

    func testTheTitleCountsEveryRow() {
        XCTAssertEqual(DigestWindowRows.title(digest()), "While you were away (10)")
    }

    func testTheWorktreeIsASubLabel() {
        let cache = RepoIdentityCache(resolver: { _ in RepoLabel(repo: "govapps", worktree: "fix-1") }, background: { $0() }, deliver: { $0() })
        _ = cache.label(cwd: "a") // the first read answers with the fallback while git resolves; the second sees the answer
        let d = AwayDigest.build(since: at(0), terminal: [], done: [done("a", 1)], recent: [],
                                 label: { cache.label(cwd: $0, project: $1) }, cap: .max)
        XCTAssertEqual(DigestWindowRows.rows(from: d).first?.name, "govapps / fix-1")
    }

    /// The window never touches the digest's state: reading rows from the model leaves it as it was.
    func testReadingTheRowsDoesNotDismissOrMarkSeenTheNotchDigest() {
        let cache = RepoIdentityCache(resolver: { RepoResolver.fallback(cwd: $0) }, background: { $0() }, deliver: { $0() })
        var locked = true
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("chippy-test-\(UUID()).jsonl")), identities: cache)
        m.awaySignal = { (locked, 0) }
        m.sweep(now: at(0))
        m.apply(HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"Stop","cwd":"/x/p","last_assistant_message":"SECRET"}"#.utf8))!, now: at(50))
        locked = false; m.sweep(now: at(400))
        let before = m.awayDigest
        XCTAssertNotNil(before)
        _ = DigestWindowRows.rows(from: m.awayDigest)
        _ = DigestWindowRows.title(m.awayDigest)
        XCTAssertEqual(m.awayDigest, before)
        XCTAssertFalse(m.restOpen, "the notch panel was not opened or closed")
    }
}
