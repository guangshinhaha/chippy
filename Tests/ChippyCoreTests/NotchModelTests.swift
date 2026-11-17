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
        XCTAssertFalse(m.visible)
        XCTAssertEqual(m.state, ChippyState.working)
    }

    func testFinishedChipIsStickyAndClearsOnlyWhenAcknowledged() {
        let m = model(); let t = Date()
        m.apply(ev("UserPromptSubmit"), now: t)
        m.apply(ev("Stop"), now: t)
        XCTAssertTrue(m.visible); XCTAssertEqual(m.density, Density.compact)
        m.sweep(now: t.addingTimeInterval(120))                 // well past the old 6s toast
        XCTAssertTrue(m.visible)
        m.dismissDone()
        XCTAssertFalse(m.visible)
    }

    func testFinishedChipAgesOutAfterTenMinutes() {
        let m = model(); let t = Date()
        m.apply(ev("Stop"), now: t)
        m.sweep(now: t.addingTimeInterval(NotchModel.doneSeconds + 1))
        XCTAssertFalse(m.visible)
    }

    func testClickingTheChipOpensDetailAndAgainGoesBack() {
        let m = model(); let t = Date()
        m.apply(ev("Stop"), now: t)
        m.toggleOpen(); XCTAssertEqual(m.density, Density.expanded); XCTAssertTrue(m.doneOpen)
        m.toggleOpen(); XCTAssertEqual(m.density, Density.compact)
        m.toggleOpen(); m.dismissDone()
        XCTAssertFalse(m.visible)
    }

    func testNewPromptDismissesTheChip() {
        let m = model(); let t = Date()
        m.apply(ev("Stop"), now: t)
        m.apply(ev("UserPromptSubmit"), now: t)
        XCTAssertFalse(m.visible)
    }

    func testAnotherThreadsPromptDoesNotDismissMyChip() {
        let m = model(); let t = Date()
        m.apply(ev("Stop", "a"), now: t)
        m.apply(ev("UserPromptSubmit", "b"), now: t)
        XCTAssertTrue(m.visible)
    }

    func testAgentWorktreeIsLabelledByRepoAndNeverShowsAChip() {
        let cwd = "/Users/x/shinstack/.claude/worktrees/agent-afe33cb8"
        let p = HookPayload(json: Data(#"{"session_id":"w","hook_event_name":"Stop","cwd":"\#(cwd)"}"#.utf8))!
        XCTAssertEqual(p.project, "shinstack")
        let m = model()
        m.apply(p)
        XCTAssertFalse(m.visible)
    }

    func testClickPeeksSessionListAndSecondClickHidesIt() {
        let m = model()
        m.apply(ev("SessionStart"))
        m.toggleOpen(); XCTAssertTrue(m.visible); XCTAssertEqual(m.density, Density.expanded)
        m.toggleOpen(); XCTAssertFalse(m.visible)
    }

    func testClickWithNoSessionsStaysCollapsed() {
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")))
        m.toggleOpen()
        XCTAssertEqual(m.density, Density.collapsed)
        XCTAssertFalse(m.pinnedOpen)
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
}
