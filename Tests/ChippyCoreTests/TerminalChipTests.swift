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
                                                       "options": [["label": "A, x", "description": "a"], ["label": "B", "description": "b"]]]]]

    func testUnanswerableQuestionCreatesChipWithRepoOnly() {
        let m = model()
        m.receiveApproval(perm("AskUserQuestion", multi), Connection.detached())
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.terminalItems.count, 1)
        XCTAssertEqual(m.terminalItems[0].glance, "api-server · asked in terminal")
        XCTAssertEqual(m.density, .compact); XCTAssertFalse(m.resting); XCTAssertEqual(m.state, .needsYou)
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
        conn.respond(nil)
        m.sweep(now: Date().addingTimeInterval(TimeInterval(SettingsInstaller.defaultApprovalTimeout) + 1))
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.terminalItems.map(\.glance), ["api-server · asked in terminal"])
        XCTAssertFalse(String(reflecting: m.terminalItems).contains("secret-dir"))
    }

    func testGoneInsideTheWindowIsATerminalAnswerNoChip() {
        let m = model()
        let conn = Connection.detached()
        m.receiveApproval(perm("Bash", ["command": "ls"]), conn)
        conn.respond(nil)
        m.sweep(now: Date().addingTimeInterval(3))
        XCTAssertTrue(m.pending.isEmpty); XCTAssertTrue(m.terminalItems.isEmpty)
    }

    func testStaleResolveBehavesLikeSweepAndUsesPayloadHost() {
        let late = Date().addingTimeInterval(TimeInterval(SettingsInstaller.defaultApprovalTimeout) + 1)
        let m = model(); let c = Connection.detached()
        let json: [String: Any] = ["session_id": "s1", "hook_event_name": "PermissionRequest", "cwd": "/Users/x/repos/api-server",
            "chippy_branch": "main", "tool_name": "Bash", "tool_input": ["command": "ls"], "chippy_host_pid": 123]
        m.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: json))!, c)
        c.respond(nil)
        m.resolve(m.pending[0].id, .allow, now: late)
        XCTAssertEqual(m.terminalItems.count, 1)
        XCTAssertEqual(m.terminalItems[0].host?.pid, 123) // payload host fallback, same as receiveApproval
        let early = model(); let c2 = Connection.detached()
        early.receiveApproval(perm("Bash", ["command": "ls"]), c2); c2.respond(nil)
        early.resolve(early.pending[0].id, .allow, now: Date().addingTimeInterval(2))
        XCTAssertTrue(early.terminalItems.isEmpty)
    }

    func testOnlyBoundaryOrSameToolPostClearsOthersStay() {
        let m = model(); let t0 = Date()
        m.receiveApproval(perm("AskUserQuestion", multi, sid: "s1"), Connection.detached())
        m.receiveApproval(perm("AskUserQuestion", multi, sid: "s2"), Connection.detached())
        func post(_ tool: String, _ sid: String) -> HookPayload {
            HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"PostToolUse","cwd":"/x/api-server","tool_name":"\#(tool)"}"#.utf8))!
        }
        m.apply(hook("PreToolUse", "s1"), now: t0.addingTimeInterval(5))      // parallel/subagent noise: stays
        m.apply(post("Bash", "s1"), now: t0.addingTimeInterval(5))            // other tool: stays
        m.apply(post("AskUserQuestion", "s1"), now: t0.addingTimeInterval(1)) // inside the 2s grace: stays
        XCTAssertEqual(m.terminalItems.count, 2)
        m.apply(post("AskUserQuestion", "s1"), now: t0.addingTimeInterval(5))
        XCTAssertEqual(m.terminalItems.map(\.sessionId), ["s2"])
        for ev in ["UserPromptSubmit", "Stop", "SessionEnd"] {
            let x = model()
            x.receiveApproval(perm("AskUserQuestion", multi, sid: "s1"), Connection.detached())
            x.apply(hook(ev, "s1"))
            XCTAssertTrue(x.terminalItems.isEmpty, ev)
        }
    }

    func testChipNeverOverridesWorking() {
        let m = model()
        m.apply(hook("UserPromptSubmit", "s1"))
        m.receiveApproval(perm("AskUserQuestion", multi, sid: "s2"), Connection.detached())
        XCTAssertEqual(m.state, .working)
        XCTAssertFalse(m.tall)
    }

    func testExpiresAfterTenMinutes() {
        let m = model()
        let t0 = Date()
        m.receiveApproval(perm("AskUserQuestion", multi), Connection.detached())
        m.sweep(now: t0.addingTimeInterval(NotchModel.doneSeconds - 5))
        XCTAssertEqual(m.terminalItems.count, 1)
        m.sweep(now: t0.addingTimeInterval(NotchModel.doneSeconds + 5))
        XCTAssertTrue(m.terminalItems.isEmpty)
        XCTAssertTrue(m.resting)
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
