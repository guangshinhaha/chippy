import XCTest
@testable import ChippyCore

private func payload(_ o: [String: Any]) -> HookPayload {
    HookPayload(json: try! JSONSerialization.data(withJSONObject: o))!
}

final class LiveGlanceTests: XCTestCase {
    private func tool(_ sid: String, _ ev: String, _ name: String, input: [String: Any] = [:]) -> HookPayload {
        payload(["session_id": sid, "cwd": "/w/proj", "hook_event_name": ev, "tool_name": name, "tool_input": input])
    }

    func testMapping() {
        XCTAssertEqual(LiveGlance.word(forTool: "Read"), "Reading")
        XCTAssertEqual(LiveGlance.word(forTool: "Edit"), "Editing")
        XCTAssertEqual(LiveGlance.word(forTool: "MultiEdit"), "Editing")
        XCTAssertEqual(LiveGlance.word(forTool: "Write"), "Editing")
        XCTAssertEqual(LiveGlance.word(forTool: "Bash"), "Running")
        XCTAssertEqual(LiveGlance.word(forTool: "Grep"), "Searching")
        XCTAssertEqual(LiveGlance.word(forTool: "Glob"), "Searching")
    }

    func testUnknownAndMcpToolsSayWorkingNeverTheirName() {
        for name in ["SomethingNew", "mcp__acme_crm__lookup", "", "read", "Bash "] {
            XCTAssertEqual(LiveGlance.word(forTool: name), "Working", name)
        }
        XCTAssertEqual(LiveGlance.word(forTool: nil), "Working")
    }

    func testEveryAllowlistedWordIsPlain() {
        let words: Set = ["Reading", "Editing", "Running", "Searching", "Delegating", "Planning", "Working", "Thinking"]
        for t in ["Read", "Edit", "Write", "Bash", "Grep", "Glob", "Task", "TodoWrite", "WebFetch", "x"] {
            XCTAssertTrue(words.contains(LiveGlance.word(forTool: t)))
        }
    }

    func testLabelUpdatesOnEachEventAndClearsOnStop() {
        var s = SessionStore()
        s.apply(payload(["session_id": "a", "cwd": "/w/proj", "hook_event_name": "UserPromptSubmit", "prompt": "hi"]))
        XCTAssertEqual(s.rows[0].activity, "Thinking")
        s.apply(tool("a", "PreToolUse", "Read"))
        XCTAssertEqual(s.rows[0].activity, "Reading")
        s.apply(tool("a", "PostToolUse", "Read"))
        XCTAssertEqual(s.rows[0].activity, "Thinking")
        s.apply(tool("a", "PreToolUse", "Bash"))
        XCTAssertEqual(s.rows[0].activity, "Running")
        s.apply(tool("a", "PreToolUse", "mcp__x__y"))
        XCTAssertEqual(s.rows[0].activity, "Working")
        s.apply(payload(["session_id": "a", "hook_event_name": "Stop"]))
        XCTAssertNil(s.rows[0].activity)
        XCTAssertTrue(s.glanceRows.isEmpty)
    }

    func testSessionStartAndEndClear() {
        var s = SessionStore()
        s.apply(tool("a", "PreToolUse", "Edit"))
        s.apply(payload(["session_id": "a", "hook_event_name": "SessionStart"]))
        XCTAssertNil(s.rows[0].activity)
        s.apply(tool("a", "PreToolUse", "Edit"))
        s.apply(payload(["session_id": "a", "hook_event_name": "SessionEnd"]))
        XCTAssertTrue(s.rows.isEmpty); XCTAssertTrue(s.glanceRows.isEmpty)
    }

    func testOneLinePerRunningSessionNewestFirst() {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        s.apply(tool("a", "PreToolUse", "Edit"), now: t0)
        s.apply(tool("b", "PreToolUse", "Grep"), now: t0.addingTimeInterval(5))
        s.apply(tool("c", "PreToolUse", "Bash"), now: t0.addingTimeInterval(9))
        s.apply(payload(["session_id": "c", "hook_event_name": "Stop"]), now: t0.addingTimeInterval(10))
        XCTAssertEqual(s.glanceRows.map(\.id), ["b", "a"])
        XCTAssertEqual(s.glanceRows.map(\.activity), ["Searching", "Editing"])
    }

    /// Privacy: no tool input (path, command, prompt) reaches the glance word.
    func testToolInputNeverLeaksIntoTheWord() {
        var s = SessionStore()
        s.apply(tool("a", "PreToolUse", "Bash", input: ["command": "curl https://secret.example/token"]))
        s.apply(tool("b", "PreToolUse", "Edit", input: ["file_path": "/Users/me/students/Marks.xlsx"]))
        for r in s.glanceRows {
            let a = r.activity ?? ""
            XCTAssertFalse(a.contains("secret") || a.contains("Marks") || a.contains("/") || a.contains("curl"))
        }
    }

    @MainActor func testPanelLinesListRunningFirstThenIdle() {
        let m = NotchModel()
        let t0 = Date(timeIntervalSince1970: 2000)
        m.apply(payload(["session_id": "idle", "cwd": "/w/a", "hook_event_name": "SessionStart"]), now: t0.addingTimeInterval(20))
        m.apply(tool("old", "PreToolUse", "Read"), now: t0)
        m.apply(tool("new", "PreToolUse", "Bash"), now: t0.addingTimeInterval(5))
        XCTAssertEqual(m.glanceSessions.map(\.id), ["new", "old", "idle"])
        XCTAssertNil(m.glanceSessions.last?.activity)
    }

    /// The glance rides on the existing session list: a model apply must not open a card, fold, or start a sound.
    @MainActor func testGlanceEventsDoNotPopCardsOrSound() {
        let m = NotchModel()
        var sounds = 0
        m.onSound = { _, _, _, _ in sounds += 1 }
        m.apply(tool("a", "PreToolUse", "Edit"))
        XCTAssertEqual(m.sessions.first?.activity, "Editing")
        XCTAssertEqual(m.density, .collapsed)
        XCTAssertTrue(m.pending.isEmpty); XCTAssertFalse(m.folded)
        XCTAssertEqual(sounds, 0)
        m.apply(tool("a", "PostToolUse", "Edit"))
        XCTAssertEqual(m.density, .collapsed)
        XCTAssertEqual(sounds, 0)
    }
}
