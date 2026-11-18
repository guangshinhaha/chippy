import XCTest
@testable import ChippyCore

/// Issue #42: a question/approval that fell back to the terminal leaves a sticky `repo · asked in terminal` chip.
final class TerminalChipTests: XCTestCase {
    private func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID()).jsonl")))
    }
    private func hook(_ ev: String, _ sid: String = "s1") -> HookPayload {
        HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"\#(ev)","cwd":"/Users/x/repos/api-server","chippy_branch":"main"}"#.utf8))!
    }
    private func perm(_ tool: String, _ input: [String: Any], sid: String = "s1") -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: ["session_id": sid, "hook_event_name": "PermissionRequest",
            "cwd": "/Users/x/repos/api-server", "chippy_branch": "main", "tool_name": tool, "tool_input": input]))!
    }
    private let multi: [String: Any] = ["questions": [["question": "SECRET Q?", "header": "h", "multiSelect": true,
                                                       "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]]]]

    func testUnanswerableQuestionCreatesChipWithRepoOnly() {
        let m = model()
        m.receiveApproval(perm("AskUserQuestion", multi), Connection.detached())
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.terminalItems.count, 1)
        XCTAssertEqual(m.terminalItems[0].glance, "api-server · asked in terminal")
        XCTAssertEqual(m.density, .compact); XCTAssertTrue(m.visible); XCTAssertEqual(m.state, .needsYou)
    }

    func testChipHoldsNoContent() {
        let m = model()
        m.receiveApproval(perm("AskUserQuestion", multi), Connection.detached())
        XCTAssertFalse(String(reflecting: m.terminalItems).contains("SECRET"))
        XCTAssertFalse(m.terminalItems[0].glance.contains("SECRET"))
        XCTAssertFalse(m.terminalItems[0].glance.contains("/Users"))
    }

    func testTimedOutApprovalCreatesChip() {
        let m = model()
        let conn = Connection.detached()
        m.receiveApproval(perm("Bash", ["command": "rm -rf secret-dir"]), conn)
        XCTAssertTrue(m.terminalItems.isEmpty)
        conn.respond(nil)
        m.sweep()
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.terminalItems.map(\.glance), ["api-server · asked in terminal"])
        XCTAssertFalse(String(reflecting: m.terminalItems).contains("secret-dir"))
    }

    func testNextEventOfSameSessionClearsOthersStay() {
        for ev in ["PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop", "SessionEnd"] {
            let m = model()
            m.receiveApproval(perm("AskUserQuestion", multi, sid: "s1"), Connection.detached())
            m.receiveApproval(perm("AskUserQuestion", multi, sid: "s2"), Connection.detached())
            m.apply(hook(ev, "s1"))
            XCTAssertEqual(m.terminalItems.map(\.sessionId), ["s2"], ev)
        }
    }

    func testExpiresAfterTenMinutes() {
        let m = model()
        let t0 = Date()
        m.receiveApproval(perm("AskUserQuestion", multi), Connection.detached())
        m.sweep(now: t0.addingTimeInterval(NotchModel.doneSeconds - 5))
        XCTAssertEqual(m.terminalItems.count, 1)
        m.sweep(now: t0.addingTimeInterval(NotchModel.doneSeconds + 5))
        XCTAssertTrue(m.terminalItems.isEmpty)
        XCTAssertFalse(m.visible)
    }

    func testRepeatReplacesAndDismissClears() {
        let m = model()
        m.receiveApproval(perm("AskUserQuestion", multi), Connection.detached())
        m.receiveApproval(perm("AskUserQuestion", multi), Connection.detached())
        XCTAssertEqual(m.terminalItems.count, 1)
        m.toggleOpen(); XCTAssertEqual(m.density, .expanded)
        m.dismissTerminal("s1")
        XCTAssertTrue(m.terminalItems.isEmpty); XCTAssertEqual(m.density, .collapsed)
    }

    func testSilentAndSingleSelectStillGetsCard() {
        let m = model()
        var sounds = 0
        m.onSound = { _, _, _ in sounds += 1 }
        m.receiveApproval(perm("AskUserQuestion", multi), Connection.detached())
        XCTAssertEqual(sounds, 0)
        let single: [String: Any] = ["questions": [["question": "Q?", "header": "h", "multiSelect": false, "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]]]]
        m.receiveApproval(perm("AskUserQuestion", single, sid: "s2"), Connection.detached())
        XCTAssertEqual(m.pending.count, 1); XCTAssertEqual(m.terminalItems.count, 1)
    }
}
