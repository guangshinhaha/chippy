import XCTest
@testable import ChippyCore

final class NotchModelTests: XCTestCase {
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

    func testFinishedShowsABriefToastThenHides() {
        let m = model(); let t = Date()
        m.apply(ev("UserPromptSubmit"), now: t)
        m.apply(ev("Stop"), now: t)
        XCTAssertTrue(m.visible); XCTAssertEqual(m.density, Density.compact)
        m.sweep(now: t.addingTimeInterval(NotchModel.toastSeconds + 1))
        XCTAssertFalse(m.visible)
    }

    func testNewPromptDismissesTheToast() {
        let m = model(); let t = Date()
        m.apply(ev("Stop"), now: t)
        m.apply(ev("UserPromptSubmit"), now: t)
        XCTAssertFalse(m.visible)
    }

    func testAnotherThreadsPromptDoesNotDismissMyToast() {
        let m = model(); let t = Date()
        m.apply(ev("Stop", "a"), now: t)
        m.apply(ev("UserPromptSubmit", "b"), now: t)
        XCTAssertTrue(m.visible)
    }

    func testAgentWorktreeIsLabelledByRepoAndNeverToasts() {
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
}
