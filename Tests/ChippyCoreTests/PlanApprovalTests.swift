import XCTest
@testable import ChippyCore

final class PlanProposalStructureTests: XCTestCase {
    func make(_ plan: String) -> PlanProposal? { PlanProposal.make(tool: "ExitPlanMode", input: ["plan": plan]) }

    func testTitleAndSteps() {
        let p = make("# Add login\n\nContext line\n1. First\n2) Second\n- third\n")!
        XCTAssertEqual(p.title, "Add login")
        XCTAssertEqual(p.lines, ["Context line", "1. First", "2) Second", "- third"])
        XCTAssertEqual(p.stepCount, 3)
    }
    func testNoHeadingMeansNoTitle() {
        let p = make("Just do it\n1. A")!
        XCTAssertNil(p.title); XCTAssertEqual(p.lines.count, 2)
    }
    func testHashOnlyFirstLineIsNotATitle() { XCTAssertNil(make("###\nbody")?.title) }
    func testHiddenCharsStrippedPerLineAndCounted() {
        let p = make("# T\u{202E}itle\nrm\u{200B} -rf\u{E0041}")!
        XCTAssertEqual(p.title, "Title"); XCTAssertEqual(p.lines, ["rm -rf"]); XCTAssertEqual(p.hiddenRemoved(expanded: true), 3)
    }
    func testNewlinesAreNotCountedAsHidden() { XCTAssertEqual(make("a\r\nb\tc\u{2028}d")?.hiddenRemoved(expanded: true), 0) }
    func testTruncationAlwaysDisclosed() {
        XCTAssertFalse(make("1. a\n2. b")!.truncated)
        XCTAssertTrue(make("x " + String(repeating: "y", count: 400))!.truncated)                 // row over the 2-line limit
        XCTAssertTrue(make((1...30).map { "\($0). s" }.joined(separator: "\n"))!.truncated)       // more rows than the expanded view
        XCTAssertTrue(make(String(repeating: "a\n", count: 30_000))!.truncated)                   // scan cap
        XCTAssertTrue(make((1...15).map { _ in String(repeating: "w", count: 139) }.joined(separator: "\n"))!.truncated) // char budget
    }
    func testStepCountCoversWholeScannedPlan() {
        XCTAssertEqual(make((1...30).map { "\($0). s" }.joined(separator: "\n"))?.stepCount, 30)
    }
    func testOnlyHashSpaceIsATitle() {
        XCTAssertNil(make("#!/bin/sh\nrun")?.title); XCTAssertNil(make("#1 item\nx")?.title); XCTAssertNil(make("#tag\nx")?.title)
        XCTAssertEqual(make("## Plan\nx")?.title, "Plan")
    }
    func testHiddenCountsOnlyDisplayedRowsAndNotSeparators() {
        XCTAssertEqual(make("a\u{0B}b\u{0C}c\u{85}d")?.hiddenRemoved(expanded: true), 0)
        let late = (1...20).map { "row \($0)" }.joined(separator: "\n") + "\nz\u{200B}"
        XCTAssertEqual(make(late)?.hiddenRemoved(expanded: true), 0)
    }
    func testFoldedAndExpandedViews() {
        let p = make((1...30).map { "\($0). step" }.joined(separator: "\n"))!
        XCTAssertEqual(p.visible(expanded: false).shown.count, 5)
        XCTAssertEqual(p.visible(expanded: false).hidden, p.lines.count - 5)
        XCTAssertEqual(p.visible(expanded: true).shown.count, 16)
        XCTAssertTrue(p.canExpand)
        XCTAssertFalse(make("1. a\n2. b")!.canExpand)
        let shortTruncated = make("x " + String(repeating: "y", count: 400))!
        XCTAssertTrue(shortTruncated.truncated); XCTAssertFalse(shortTruncated.canExpand)
    }
    func testIsStepAsciiDigitsOnly() {
        XCTAssertTrue(PlanProposal.isStep("5. foo")); XCTAssertFalse(PlanProposal.isStep("5\u{301}. foo"))
    }
    func testHiddenCountsOnlyShownPortion() {
        let rows = (1...8).map { $0 == 7 ? "row\u{200B} 7" : "row \($0)" } + [String(repeating: "a", count: 150) + "\u{200B}"]
        let p = make(rows.joined(separator: "\n"))!
        XCTAssertEqual(p.hiddenRemoved(expanded: false), 0)  // row 7 is folded away
        XCTAssertEqual(p.hiddenRemoved(expanded: true), 1)   // row 7 shown; the zero-width past 140 chars is not
    }
    func testLinesStayWithinBudgetAndHugePlanIsBounded() {
        let p = make(String(repeating: "word ", count: 100_000))!
        XCTAssertTrue(p.truncated)
        XCTAssertLessThanOrEqual(p.lines.joined().count, PlanProposal.maxChars)
        let many = make((1...5000).map { "line \($0)" }.joined(separator: "\n"))!
        XCTAssertLessThanOrEqual(many.lines.joined().count, PlanProposal.maxChars)
    }
}

/// Socket-pair fixture shared by the plan tests (no borrowed XCTestCase instance).
struct PlanFixture {
    func pair() -> (Connection, Int32) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (Connection(fd: fds[0]), fds[1])
    }
    func reply(_ fd: Int32) -> [String: Any]? {
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return readLine(fd: fd).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    func model(planCard: Bool = true, clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) -> NotchModel {
        let m = NotchModel(always: AlwaysStore(url: nil),
                           log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")), clock: clock)
        m.planCardEnabled = planCard
        return m
    }
    func payload(_ tool: String = "Bash", _ input: [String: Any] = ["command": "ls"]) -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s", "cwd": "/w/api", "hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input]))!
    }
}

final class PlanApprovalTests: XCTestCase {
    let input: [String: Any] = ["plan": "# P\n1. a\n2. b", "planFilePath": "/Users/me/.claude/plans/x.md"]
    let h = PlanFixture()

    func req(_ tool: String = "ExitPlanMode", _ input: [String: Any]? = nil) -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s", "cwd": "/w/api", "hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input ?? self.input]))!
    }

    func testParsedPlanOnRequest() {
        let m = h.model(); let (c, _) = h.pair()
        m.receiveApproval(req(), c)
        XCTAssertEqual(m.pending[0].plan?.title, "P"); XCTAssertTrue(m.pending[0].isPlanApproval)
    }
    func testApproveEchoesInputAsUpdatedInput() {
        let m = h.model(); let (c, f) = h.pair()
        m.receiveApproval(req(), c)
        m.resolve(m.pending[0].id, .allow)
        let r = h.reply(f)!
        XCTAssertEqual(r["behavior"] as? String, "allow")
        let u = r["updatedInput"] as? [String: Any]
        XCTAssertEqual(u?["plan"] as? String, "# P\n1. a\n2. b")
        XCTAssertEqual(u?["planFilePath"] as? String, "/Users/me/.claude/plans/x.md")
    }
    func testKeepPlanningDeniesWithMessageNoInterruptNoPlanText() {
        let m = h.model(); let (c, f) = h.pair()
        m.receiveApproval(req(), c)
        m.resolve(m.pending[0].id, .deny)
        let r = h.reply(f)!
        XCTAssertEqual(r["behavior"] as? String, "deny")
        XCTAssertFalse((r["message"] as? String ?? "").isEmpty)
        XCTAssertNil(r["interrupt"]); XCTAssertNil(r["updatedInput"])
        let wire = String(data: try! JSONSerialization.data(withJSONObject: r), encoding: .utf8)!
        XCTAssertFalse(wire.contains("# P")); XCTAssertFalse(wire.contains("x.md"))
    }
    func testMissingPlanFallsToTerminal() {
        let m = h.model(); let (c, f) = h.pair()
        m.receiveApproval(req("ExitPlanMode", [:]), c)
        XCTAssertTrue(m.pending.isEmpty)                   // no generic Allow card
        XCTAssertNil(h.reply(f))                           // hook got nothing: terminal prompts
        XCTAssertEqual(m.terminalItems.count, 1)
    }
    func testFlagOffFallsToTerminal() {
        let m = h.model(planCard: false); let (c, f) = h.pair()
        m.receiveApproval(req(), c)
        XCTAssertTrue(m.pending.isEmpty); XCTAssertNil(h.reply(f))
    }
    func testMissingEchoFallsBackToNil() {
        XCTAssertNotNil(NotchModel.planReply(.allow, input: ["plan": "x"]))
        XCTAssertNil(NotchModel.planReply(.allow, input: ["bad": Date()]))   // not serialisable: nil, never a crash
    }
    func testResolveWithoutEchoRepliesNothing() {
        // Echo is only absent if it was consumed; a second resolve is stale and ignored, never a bare allow.
        let m = h.model(); let (c, f) = h.pair()
        m.receiveApproval(req(), c)
        let id = m.pending[0].id
        m.resolve(id, .allow)
        XCTAssertEqual(h.reply(f)?["behavior"] as? String, "allow")
        m.resolve(id, .allow)
        XCTAssertTrue(m.pending.isEmpty)
    }
    func testHotkeyNeedsExpandedFoldedPlan() {
        let long = ["plan": "# T\n" + (1...10).map { "\($0). step" }.joined(separator: "\n")]
        let m = h.model(); let (c, _) = h.pair()
        m.receiveApproval(req("ExitPlanMode", long), c)
        let r = m.pending[0]
        XCTAssertFalse(m.hotkeyMayApprove(r))
        m.setPlanExpanded(r.id, true)
        XCTAssertTrue(m.hotkeyMayApprove(r))
        m.setPlanExpanded(r.id, false)
        XCTAssertFalse(m.hotkeyMayApprove(r))
        let (c2, _) = h.pair()
        m.receiveApproval(req(), c2)                       // a short plan is fully shown folded
        XCTAssertTrue(m.hotkeyMayApprove(m.pending[1]))
        let (c3, _) = h.pair()
        m.receiveApproval(h.payload(), c3)
        XCTAssertTrue(m.hotkeyMayApprove(m.pending[2]))
        let (c4, _) = h.pair()
        m.receiveApproval(req("ExitPlanMode", ["plan": (1...30).map { "\($0). step" }.joined(separator: "\n")]), c4) // truncated: never by key
        let t = m.pending[3]; m.setPlanExpanded(t.id, true)
        XCTAssertFalse(m.hotkeyMayApprove(t))
    }
    func testAlwaysIsNoOpOnPlanCard() {
        let m = h.model(); let (c, f) = h.pair()
        m.receiveApproval(req(), c)
        m.resolve(m.pending[0].id, .always)
        XCTAssertEqual(m.pending.count, 1); XCTAssertNil(h.reply(f))
    }
    func testStaleResolveOnPlanDropsAndCleansEcho() {
        let m = h.model(); let (c, f) = h.pair()
        m.receiveApproval(req(), c)
        close(f)                                           // hook gave up
        m.resolve(m.pending[0].id, .allow)
        XCTAssertTrue(m.pending.isEmpty)
    }
    func testHandBackOnPlanCleansEcho() {
        let m = h.model(); let (c, f) = h.pair()
        m.receiveApproval(req(), c)
        m.handBack(m.pending[0].id)
        XCTAssertTrue(m.pending.isEmpty); XCTAssertNil(h.reply(f))
    }
    func testAlwaysIsRefusedAndNeverStored() {
        let store = AlwaysStore(url: nil)
        let m = NotchModel(always: store, log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")))
        m.planCardEnabled = true
        let (c, f) = h.pair()
        m.receiveApproval(req(), c)
        let r0 = m.pending[0]
        m.resolve(r0.id, .always)
        XCTAssertEqual(m.pending.count, 1)                 // refused, card stays
        XCTAssertNil(h.reply(f))
        XCTAssertFalse(store.contains(r0))
        store.insert(r0)                                   // even a stored key never auto-approves a plan
        let (c2, f2) = h.pair()
        m.receiveApproval(req(), c2)
        XCTAssertEqual(m.pending.count, 2); XCTAssertNil(h.reply(f2))
    }
    func testOtherToolsUnchanged() {
        let m = h.model(); let (c, f) = h.pair()
        m.receiveApproval(h.payload(), c)
        XCTAssertNil(m.pending[0].plan)
        m.resolve(m.pending[0].id, .allow)
        XCTAssertNil(h.reply(f)?["updatedInput"])
    }
    func testPinOnExpandStopsFold() {
        var t: TimeInterval = 0
        let m = h.model(clock: { t })
        let (c, _) = h.pair()
        m.receiveApproval(req(), c)
        m.setPlanExpanded(m.pending[0].id, true)
        t = 100; m.sweep()
        XCTAssertFalse(m.folded)
    }
    func testExpandedPlanPrunedWhenResolved() {
        let m = h.model(); let (c, _) = h.pair(); let (c2, _) = h.pair()
        m.receiveApproval(req(), c); m.receiveApproval(req(), c2)
        let id = m.pending[0].id
        m.setPlanExpanded(id, true)
        XCTAssertTrue(m.expandedPlans.contains(id))
        m.resolve(id, .deny)
        XCTAssertTrue(m.expandedPlans.isEmpty)
    }
    func testIsStepAsciiDigitsOnly() {
        XCTAssertTrue(PlanProposal.isStep("1. a")); XCTAssertTrue(PlanProposal.isStep("12) a"))
        XCTAssertFalse(PlanProposal.isStep("\u{BD}. a")); XCTAssertFalse(PlanProposal.isStep("\u{2460} a")); XCTAssertFalse(PlanProposal.isStep("\u{661}. a"))
    }
}
