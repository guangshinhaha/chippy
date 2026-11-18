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
        XCTAssertNil(s.rows[0].activityAt)
    }

    func testSessionStartAndEndClear() {
        var s = SessionStore()
        s.apply(tool("a", "PreToolUse", "Edit"))
        s.apply(payload(["session_id": "a", "hook_event_name": "SessionStart"]))
        XCTAssertNil(s.rows[0].activity)
        s.apply(tool("a", "PreToolUse", "Edit"))
        s.apply(payload(["session_id": "a", "hook_event_name": "SessionEnd"]))
        XCTAssertTrue(s.rows.isEmpty); XCTAssertTrue(s.glanceOrder().isEmpty)
    }

    func testOneLinePerRunningSessionNewestFirst() {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        s.apply(tool("a", "PreToolUse", "Edit"), now: t0)
        s.apply(tool("b", "PreToolUse", "Grep"), now: t0.addingTimeInterval(5))
        s.apply(tool("c", "PreToolUse", "Bash"), now: t0.addingTimeInterval(9))
        s.apply(payload(["session_id": "c", "hook_event_name": "Stop"]), now: t0.addingTimeInterval(10))
        let now = t0.addingTimeInterval(11)
        XCTAssertEqual(s.glanceOrder(now: now).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(s.glanceOrder(now: now).map(\.activity), ["Searching", "Editing", nil])
    }

    /// Privacy: no tool input (path, command, prompt) reaches the glance word.
    func testToolInputNeverLeaksIntoTheWord() {
        var s = SessionStore()
        s.apply(tool("a", "PreToolUse", "Bash", input: ["command": "curl https://secret.example/token"]))
        s.apply(tool("b", "PreToolUse", "Edit", input: ["file_path": "/Users/me/students/Marks.xlsx"]))
        for r in s.glanceOrder() {
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
        let o = m.glanceSessions(now: t0.addingTimeInterval(30))
        XCTAssertEqual(o.map(\.id), ["new", "old", "idle"])
        XCTAssertNil(o.last?.activity)
    }

    @MainActor func testPanelOrderIsStoredAndTiesBreakOnId() {
        let m = NotchModel()
        let t = Date(timeIntervalSince1970: 3000)
        for id in ["c", "a", "b"] { m.apply(tool(id, "PreToolUse", "Read"), now: t) }
        let n = t.addingTimeInterval(1)
        XCTAssertEqual(m.glanceSessions(now: n).map(\.id), ["a", "b", "c"])
        var s = SessionStore()
        for id in ["c", "a", "b"] { s.apply(tool(id, "PreToolUse", "Read"), now: t) }
        XCTAssertEqual(m.glanceSessions(now: n).map(\.id), s.glanceOrder(now: n).map(\.id)) // one ordering
    }

    // Item 1: which events touch the word
    func testNonTurnEventsLeaveActivityUntouched() {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        s.apply(tool("a", "PreToolUse", "Edit"), now: t0)
        for ev in ["Notification", "SubagentStop", "PreCompact", "SomethingNew"] {
            s.apply(payload(["session_id": "a", "hook_event_name": ev]), now: t0.addingTimeInterval(5))
            XCTAssertEqual(s.rows[0].activity, "Editing", ev)
            XCTAssertEqual(s.rows[0].activityAt, t0, ev) // age is not refreshed either
        }
        XCTAssertNil(LiveGlance.activity(after: "Stop", tool: nil, current: "Editing"))
        XCTAssertNil(LiveGlance.activity(after: "SessionStart", tool: nil, current: "Editing"))
        XCTAssertEqual(LiveGlance.activity(after: "UserPromptSubmit", tool: nil, current: nil), "Thinking")
    }

    // Item 2: staleness, Esc or crash sends no Stop
    func testStaleWordFallsBackToState() {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        s.apply(tool("a", "PreToolUse", "Bash"), now: t0)
        let row = s.rows[0]
        XCTAssertEqual(row.liveActivity(now: t0.addingTimeInterval(90)), "Running")
        XCTAssertNil(row.liveActivity(now: t0.addingTimeInterval(91)))
        XCTAssertEqual(LiveGlance.line(for: row, now: t0.addingTimeInterval(30)).text, "Running")
        let stale = LiveGlance.line(for: row, now: t0.addingTimeInterval(120))
        XCTAssertEqual(stale.text, "Working"); XCTAssertFalse(stale.live) // still working: a long tool run is not idle
        var idleRow = row; idleRow.status = .idle
        XCTAssertEqual(LiveGlance.line(for: idleRow, now: t0.addingTimeInterval(120)).text, "Idle")
        s.apply(tool("a", "PostToolUse", "Bash"), now: t0.addingTimeInterval(100)) // a new event revives it
        XCTAssertEqual(LiveGlance.line(for: s.rows[0], now: t0.addingTimeInterval(120)).text, "Thinking")
    }

    // Item 3: real state on non-active lines
    @MainActor func testLineShowsRealState() {
        let m = NotchModel()
        let t = Date(timeIntervalSince1970: 4000)
        m.apply(payload(["session_id": "idle", "cwd": "/w/a", "hook_event_name": "SessionStart"]), now: t)
        m.apply(tool("fin", "PreToolUse", "Edit"), now: t)
        m.apply(payload(["session_id": "fin", "cwd": "/w/b", "hook_event_name": "Stop"]), now: t)
        m.apply(tool("run", "PreToolUse", "Grep"), now: t)
        func line(_ id: String) -> String { m.glanceLine(for: m.sessions.first { $0.id == id }!, now: t.addingTimeInterval(5)).text }
        XCTAssertEqual(line("idle"), "Idle")
        XCTAssertEqual(line("fin"), "Finished")
        XCTAssertEqual(line("run"), "Searching")
        let row = m.sessions.first { $0.id == "run" }!
        XCTAssertEqual(LiveGlance.line(for: row, now: t, needsYou: true).text, "Needs you")
        XCTAssertEqual(LiveGlance.line(for: row, now: t, waitingTerminal: true).text, "Waiting for you")
        XCTAssertFalse(LiveGlance.line(for: row, now: t, needsYou: true).live)
    }

    func testGlanceHeightBudget() {
        XCTAssertEqual(GlanceMetrics.height(rows: 0), 0)
        XCTAssertEqual(GlanceMetrics.height(rows: 2), 2 * GlanceMetrics.rowHeight)
        XCTAssertEqual(GlanceMetrics.height(rows: 9), 4 * GlanceMetrics.rowHeight + GlanceMetrics.moreHeight)
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

    func testThreeMinuteToolRunStaysWorking() {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        s.apply(tool("a", "PreToolUse", "Bash"), now: t0)
        let l = LiveGlance.line(for: s.rows[0], now: t0.addingTimeInterval(180))
        XCTAssertEqual(l.text, "Working"); XCTAssertFalse(l.live)
    }

    func testLatePostToolUseAfterStopDoesNotSetThinking() {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        s.apply(tool("a", "PreToolUse", "Bash"), now: t0)
        s.apply(payload(["session_id": "a", "hook_event_name": "Stop"]), now: t0.addingTimeInterval(1))
        s.apply(tool("a", "PostToolUse", "Bash"), now: t0.addingTimeInterval(2))
        XCTAssertNil(s.rows[0].activity); XCTAssertNil(s.rows[0].activityAt)
        s.apply(payload(["session_id": "a", "hook_event_name": "UserPromptSubmit", "prompt": "next"]), now: t0.addingTimeInterval(3))
        XCTAssertEqual(s.rows[0].activity, "Thinking") // a new prompt is a real new turn
    }

    func testFreshWordOutranksStaleWorkingAndNeedsYouIsFirst() {
        var s = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1000)
        for id in ["r1", "r2", "r3", "blocked"] { s.apply(tool(id, "PreToolUse", "Bash"), now: t0.addingTimeInterval(100)) }
        s.apply(tool("s", "PreToolUse", "Bash"), now: t0) // word is 150s old at `now`
        s.apply(payload(["session_id": "s", "hook_event_name": "Notification"]), now: t0.addingTimeInterval(120)) // newest updatedAt, stale word
        let o = s.glanceOrder(now: t0.addingTimeInterval(150), needsYou: ["blocked"]).map(\.id)
        XCTAssertEqual(o, ["blocked", "r1", "r2", "r3", "s"])
    }

    @MainActor func testBlockedSessionAmongFourRunningIsInVisibleRows() {
        let m = NotchModel()
        let t = Date(timeIntervalSince1970: 5000)
        m.apply(payload(["session_id": "z", "cwd": "/w/z", "hook_event_name": "PreToolUse", "tool_name": "Bash"]), now: t) // oldest
        for id in ["a", "b", "c", "d"] { m.apply(tool(id, "PreToolUse", "Edit"), now: t.addingTimeInterval(10)) }
        m.receiveApproval(payload(["session_id": "z", "cwd": "/w/z", "hook_event_name": "PermissionRequest",
                                   "tool_name": "Bash", "tool_input": ["command": "ls"]]), Connection(fd: -1), now: t.addingTimeInterval(11))
        let ids = m.glanceSessions(now: t.addingTimeInterval(20)).map(\.id)
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(ids.first, "z")
        XCTAssertLessThan(ids.firstIndex(of: "z")!, GlanceMetrics.rowCap)
    }
}
