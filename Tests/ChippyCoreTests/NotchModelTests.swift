import Darwin
import XCTest
@testable import ChippyCore

final class NotchModelTests: XCTestCase {
    func pair() -> (Connection, Int32) {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        return (Connection(fd: fds[0]), fds[1])
    }

    func testFourV1StatesAndThreeDensities() {
        XCTAssertEqual(ChippyState.allCases.count, 4)
        XCTAssertEqual(Density.allCases.count, 3)
    }

    func testAllStatesReachable() {
        let m = NotchModel()
        for s in ChippyState.allCases { m.state = s; XCTAssertEqual(m.state, s) }
    }

    private func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: nil),
                   log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")))
    }
    private func ev(_ e: String, _ sid: String = "a") -> HookPayload {
        HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"\#(e)","cwd":"/x/p"}"#.utf8))!
    }

    func testHiddenWhileSessionsJustRun() {
        let m = model()
        m.apply(ev("SessionStart")); m.apply(ev("UserPromptSubmit"))
        XCTAssertTrue(m.resting)
        XCTAssertEqual(m.state, ChippyState.working)
    }

    func testFinishedChipIsStickyAndClearsOnlyWhenAcknowledged() {
        let m = model(); let t = Date()
        m.apply(ev("UserPromptSubmit"), now: t)
        m.apply(ev("Stop"), now: t)
        XCTAssertFalse(m.resting); XCTAssertEqual(m.density, Density.compact)
        m.sweep(now: t.addingTimeInterval(120))                 // well past the old 6s toast
        XCTAssertFalse(m.resting)
        m.dismissDone()
        XCTAssertTrue(m.resting)
    }

    func testFinishedChipAgesOutAfterTenMinutes() {
        let m = model(); let t = Date()
        m.apply(ev("Stop"), now: t)
        m.sweep(now: t.addingTimeInterval(NotchModel.doneSeconds + 1))
        XCTAssertTrue(m.resting)
    }

    func testClickingTheChipOpensDetailAndAgainGoesBack() {
        let m = model(); let t = Date()
        m.apply(ev("Stop"), now: t)
        m.toggleOpen(); XCTAssertEqual(m.density, Density.expanded); XCTAssertTrue(m.doneOpen)
        m.toggleOpen(); XCTAssertEqual(m.density, Density.collapsed)
        m.toggleOpen(); m.dismissDone()
        XCTAssertTrue(m.resting)
    }

    func testThreadResumingWithoutAPromptClearsItsChipAndShowsWorking() {
        let m = model(); let t = Date()
        m.apply(ev("Stop", "a"), now: t)
        m.apply(ev("UserPromptSubmit", "b"), now: t)   // another thread starts: state must say working, chip stays
        XCTAssertEqual(m.state, ChippyState.working); XCTAssertEqual(m.doneItems.count, 1)
        m.apply(ev("PostToolUse", "a"), now: t)        // a resumes by itself
        XCTAssertTrue(m.doneItems.isEmpty)
    }

    func testNewPromptDismissesTheChip() {
        let m = model(); let t = Date()
        m.apply(ev("Stop"), now: t)
        m.apply(ev("UserPromptSubmit"), now: t)
        XCTAssertTrue(m.resting)
    }

    func testAnotherThreadsPromptDoesNotDismissMyChip() {
        let m = model(); let t = Date()
        m.apply(ev("Stop", "a"), now: t)
        m.apply(ev("UserPromptSubmit", "b"), now: t)
        XCTAssertFalse(m.resting)
    }

    func testAgentWorktreeIsLabelledByRepoAndNeverShowsAChip() {
        let cwd = "/Users/x/shinstack/.claude/worktrees/agent-afe33cb8"
        let p = HookPayload(json: Data(#"{"session_id":"w","hook_event_name":"Stop","cwd":"\#(cwd)"}"#.utf8))!
        XCTAssertEqual(p.project, "shinstack")
        let m = model()
        m.apply(p)
        XCTAssertTrue(m.resting)
    }

    func testClickPeeksSessionListAndSecondClickHidesIt() {
        let m = model()
        m.apply(ev("SessionStart"))
        m.toggleOpen(); XCTAssertFalse(m.resting); XCTAssertEqual(m.density, Density.expanded)
        m.toggleOpen(); XCTAssertTrue(m.resting)
    }

    func testClickWithNoSessionsOpensTheRestPanel() {
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")))
        m.toggleOpen()
        XCTAssertEqual(m.density, Density.expanded)
        XCTAssertFalse(m.pinnedOpen); XCTAssertTrue(m.restOpen)
    }

    func testApprovalCardCarriesFullCommandBranchAndPrompt() {
        let m = model()
        m.apply(HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","cwd":"/w/api","prompt":"fix login","chippy_branch":"fix/x"}"#.utf8))!)
        let long = String(repeating: "x", count: 300)
        let (c, _) = pair()
        m.receiveApproval(HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","cwd":"/w/api","chippy_branch":"fix/x","tool_name":"Bash","tool_input":{"command":"\#(long)"}}"#.utf8))!, c)
        let r = m.pending[0]
        XCTAssertEqual(r.detail.count, 300); XCTAssertEqual(r.branch, "fix/x"); XCTAssertEqual(r.lastPrompt, "fix login")
    }

    func testQueueIsOldestFirstAndAnsweringAdvances() {
        let m = model()
        let (c1, _) = pair(), (c2, _) = pair()
        m.receiveApproval(HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"PermissionRequest","cwd":"/w/a","tool_name":"Bash","tool_input":{"command":"one"}}"#.utf8))!, c1)
        m.receiveApproval(HookPayload(json: Data(#"{"session_id":"b","hook_event_name":"PermissionRequest","cwd":"/w/b","tool_name":"Bash","tool_input":{"command":"two"}}"#.utf8))!, c2)
        XCTAssertEqual(m.pending.first?.detail, "one")
        m.resolve(m.pending[0].id, .allow)
        XCTAssertEqual(m.pending.first?.detail, "two")
    }

    func testDoneChipCarriesClaudesReplyAndFlagsAQuestion() {
        let m = model()
        m.apply(HookPayload(json: Data(###"{"session_id":"a","hook_event_name":"Stop","cwd":"/w/api","last_assistant_message":"## Fixed it\n\nShould I bump the TTL too?"}"###.utf8))!)
        let d = m.doneItems[0]
        XCTAssertEqual(d.headline, "Fixed it"); XCTAssertTrue(d.asksYou)
        m.apply(HookPayload(json: Data(#"{"session_id":"b","hook_event_name":"Stop","cwd":"/w/web"}"#.utf8))!)
        XCTAssertEqual(m.doneItems[1].headline, "finished"); XCTAssertFalse(m.doneItems[1].asksYou)
    }

    func testClickOutsideFoldsDetailButKeepsTheChipAndApprovals() {
        let m = model()
        m.apply(ev("Stop"), now: Date())
        m.toggleOpen(); XCTAssertEqual(m.density, Density.expanded)
        m.closeDetail()
        XCTAssertEqual(m.density, Density.collapsed); XCTAssertEqual(m.doneItems.count, 1)   // folded, not dismissed
        let (c, _) = pair()
        m.receiveApproval(HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"PermissionRequest","cwd":"/w","tool_name":"Bash","tool_input":{"command":"x"}}"#.utf8))!, c)
        m.closeDetail()
        XCTAssertEqual(m.pending.count, 1); XCTAssertEqual(m.density, Density.expanded)   // approval stays
    }

    func testGlanceIsNeutralUnlessOptedIn() {
        let m = model()
        m.apply(HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"Stop","cwd":"/w/api","last_assistant_message":"Student Tan Ah Kow scored 40. Send report?"}"#.utf8))!)
        let d = m.doneItems[0]
        XCTAssertEqual(d.glance(showReply: false), "api · needs you")
        XCTAssertFalse(d.glance(showReply: false).contains("Tan"))
        XCTAssertTrue(d.glance(showReply: true).contains("Student Tan"))
    }
}
