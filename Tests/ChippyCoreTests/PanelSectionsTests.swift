import XCTest
@testable import ChippyCore

/// Issue #139: the rest panel says why each row is there. One pure function turns the live state into a count header and
/// three sections (Needs you, Working, Done); only Needs-you rows carry the prominent button.
final class PanelSectionsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let q = "Shall I go ahead and delete it?"

    // MARK: fixtures

    func session(_ id: String, _ status: SessionStatus = .working, cwd: String = "/w/api", branch: String? = "main") -> SessionRow {
        var r = SessionRow(id: id, project: URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd, branch: branch, updatedAt: now)
        r.status = status
        return r
    }
    func done(_ id: String, reply: String = "Fixed the bug.", ago: TimeInterval = 60, cwd: String = "/w/api") -> DoneItem {
        DoneItem(sessionId: id, project: URL(fileURLWithPath: cwd).lastPathComponent, branch: "main", files: 1, added: 1, removed: 0,
                 reply: reply, prompt: nil, at: now.addingTimeInterval(-ago), cwd: cwd)
    }
    func recent(_ id: String, ago: TimeInterval = 60, cwd: String = "/w/api") -> RecentItem {
        RecentItem(sessionId: id, project: URL(fileURLWithPath: cwd).lastPathComponent, at: now.addingTimeInterval(-ago), cwd: cwd)
    }
    func terminal(_ id: String, cwd: String = "/w/api") -> TerminalItem {
        TerminalItem(sessionId: id, project: URL(fileURLWithPath: cwd).lastPathComponent, at: now.addingTimeInterval(-30), tool: "Bash", cwd: cwd)
    }
    func approval(_ sid: String, cwd: String = "/w/api") -> PendingRequest {
        let json = #"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","cwd":"\#(cwd)","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        return PendingRequest(payload: HookPayload(json: Data(json.utf8))!, now: now)
    }
    func build(pending: [PendingRequest] = [], terminal: [TerminalItem] = [], done: [DoneItem] = [],
               sessions: [SessionRow] = [], recent: [RecentItem] = []) -> PanelSections.Result {
        PanelSections.build(pending: pending, terminal: terminal, done: done, sessions: sessions, recent: recent,
                            label: { RepoResolver.fallback(cwd: $0, project: $1) }, now: now)
    }
    func rows(_ r: PanelSections.Result, _ t: PanelSections.Title) -> [PanelSections.Row] { r.sections.first { $0.title == t }?.rows ?? [] }

    // MARK: header and sections

    func testZeroRowsIsAllQuietWithNoSections() {
        let r = build()
        XCTAssertEqual(r.header, "All quiet")
        XCTAssertTrue(r.sections.isEmpty)
    }

    func testOneNeedAndTwoWorking() {
        let r = build(pending: [approval("a")], sessions: [session("a"), session("b", cwd: "/w/web"), session("c", cwd: "/w/docs")])
        XCTAssertEqual(r.header, "1 needs you · 2 working")
        XCTAssertEqual(r.sections.map(\.title), [.needsYou, .working])
        XCTAssertEqual(rows(r, .needsYou).map(\.sessionId), ["a"], "the session that needs you is not also listed as working")
        XCTAssertEqual(rows(r, .working).map(\.sessionId), ["b", "c"])
    }

    func testHeaderCountsAndPlurals() {
        XCTAssertEqual(build(terminal: [terminal("a"), terminal("b")]).header, "2 need you")
        XCTAssertEqual(build(sessions: [session("a"), session("b"), session("c")]).header, "3 working")
        XCTAssertEqual(build(done: [done("a")]).header, "All quiet", "finished work that asks nothing is not a count")
    }

    func testSectionOrderIsNeedsYouWorkingDone() {
        let r = build(terminal: [terminal("t")], done: [done("d")], sessions: [session("w")])
        XCTAssertEqual(r.sections.map(\.title), [.needsYou, .working, .done])
    }

    // MARK: a session appears once

    func testASessionInBothLiveAndRecentShowsOnce() {
        let r = build(sessions: [session("a")], recent: [recent("a")])
        XCTAssertEqual(rows(r, .working).map(\.sessionId), ["a"])
        XCTAssertTrue(rows(r, .done).isEmpty)
    }

    func testASessionInDoneAndRecentShowsOnceAndEveryIdIsUnique() {
        let r = build(terminal: [terminal("t")], done: [done("d"), done("x")], sessions: [session("w"), session("d", .done)], recent: [recent("d"), recent("x"), recent("r")])
        let ids = r.sections.flatMap(\.rows).map(\.sessionId)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(Set(ids), ["t", "w", "d", "x", "r"])
    }

    func testAFinishedSessionWithAnIdleOrDoneRowIsNotWorking() {
        let r = build(sessions: [session("a", .done), session("b", .idle)], recent: [recent("a")])
        XCTAssertTrue(rows(r, .working).isEmpty)
        XCTAssertEqual(rows(r, .done).map(\.sessionId), ["a"])
    }

    // MARK: a reply that asks

    func testAFinishedReplyThatAsksAQuestionLandsInNeedsYou() {
        let r = build(done: [done("a", reply: "I changed the schema. \(q)"), done("b")])
        XCTAssertEqual(rows(r, .needsYou).map(\.sessionId), ["a"])
        XCTAssertEqual(rows(r, .needsYou).first?.kind, .asksYou)
        XCTAssertEqual(rows(r, .done).map(\.sessionId), ["b"])
        XCTAssertEqual(r.header, "1 needs you")
    }

    // MARK: buttons

    func testOnlyNeedsYouRowsHaveAButton() {
        let r = build(pending: [approval("p")], terminal: [terminal("t")], done: [done("q", reply: q), done("d")],
                      sessions: [session("w")], recent: [recent("r")])
        for section in r.sections {
            for row in section.rows { XCTAssertEqual(row.hasButton, section.title == .needsYou, "\(section.title) \(row.sessionId)") }
        }
        XCTAssertFalse(rows(r, .needsYou).isEmpty); XCTAssertFalse(rows(r, .working).isEmpty); XCTAssertFalse(rows(r, .done).isEmpty)
    }

    // MARK: Done: last 5, 30 minutes, newest first

    func testDoneKeepsTheNewestFiveWithinThirtyMinutes() {
        let items = (0..<8).map { recent("r\($0)", ago: TimeInterval(60 * ($0 + 1))) }
        XCTAssertEqual(rows(build(recent: items), .done).map(\.sessionId), ["r0", "r1", "r2", "r3", "r4"])
        let old = [recent("fresh", ago: 600), recent("stale", ago: RecentList.ttl + 1)]
        XCTAssertEqual(rows(build(recent: old), .done).map(\.sessionId), ["fresh"])
    }

    // MARK: one label style

    func testRowsCarryTheBranchWhateverSectionTheyAreIn() {
        let r = build(terminal: [terminal("t")], sessions: [session("t", branch: "fix/login"), session("w", branch: "feat/x")], recent: [recent("r")])
        XCTAssertEqual(rows(r, .needsYou).first?.branch, "fix/login", "a terminal row has no branch of its own: the live session supplies it")
        XCTAssertEqual(rows(r, .working).first?.branch, "feat/x")
    }

    func testAHashLikeWorktreeNameIsNeverTheRowLabel() {
        let hash = "t3-3f9a6c1e-62fae7136250"
        let cwd = "/Users/x/.t3/worktrees/chippy/\(hash)"
        let r = build(sessions: [session("a", cwd: cwd)])
        let label = rows(r, .working).first?.label
        XCTAssertEqual(label?.repo, "chippy")
        XCTAssertNil(label?.worktree)
        XCTAssertFalse(label?.text.contains("62fae7136250") ?? true)
    }

    func testAHashLikeWorktreeTagFromGitIsDroppedButARealOneStays() {
        let q = PanelSections.display(RepoLabel(repo: "chippy", worktree: "t3-3f9a6c1e-62fae7136250"))
        XCTAssertEqual(q, RepoLabel(repo: "chippy"))
        XCTAssertEqual(PanelSections.display(RepoLabel(repo: "chippy", worktree: "feature-login")), RepoLabel(repo: "chippy", worktree: "feature-login"))
        XCTAssertEqual(PanelSections.display(RepoLabel(repo: "chippy", worktree: "orca")), RepoLabel(repo: "chippy", worktree: "orca"))
    }

    func testHashLikeNames() {
        for n in ["62fae7136250", "t3-3f9a6c1e-62fae7136250", "agent-a1b2c3d4e5f6", "wt-0123456789ab"] { XCTAssertTrue(PanelSections.isHashLike(n), n) }
        for n in ["chippy", "feature-login", "deadbeef", "release-2026", "orca", "my-app-v2", "abcdefabcdef", ""] { XCTAssertFalse(PanelSections.isHashLike(n), n) }
    }

    // MARK: identity (#115)

    func testTheSameRepoKeepsItsIdentitySlotBeforeAndAfterItsLabelResolves() {
        let cwd = "/Users/x/.t3/worktrees/chippy/t3-3f9a6c1e-62fae7136250"
        let book = IdentityBook()
        let before = book.identity(repo: RepoResolver.fallback(cwd: cwd).repo, resolved: false)
        let after = book.identity(repo: "chippy", resolved: true)
        XCTAssertEqual(before, after, "the hash folder is not the repo name, so the mark does not flip when git answers")
    }

    func testAnUnresolvedNameThatIsNotAHashStillResolvesToItself() {
        XCTAssertEqual(RepoResolver.fallback(cwd: "/w/api").repo, "api")
    }

    func testGlyphForNonASCIIFirstLetterIsTheLetterNotAHash() {
        let b = IdentityBook()
        XCTAssertEqual(b.identity(repo: "élan").glyph, "É")
        XCTAssertEqual(b.identity(repo: "Ωmega").glyph, "Ω")
        XCTAssertEqual(b.identity(repo: "ßtool").glyph, "S")
        XCTAssertEqual(b.identity(repo: "").glyph, "#")
        XCTAssertEqual(b.identity(repo: "🚀rocket").glyph, "R", "leading symbols are skipped like separators")
    }
}
