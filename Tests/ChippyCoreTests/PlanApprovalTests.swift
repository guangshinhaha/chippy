import Darwin
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
        XCTAssertEqual(p.title, "Title"); XCTAssertEqual(p.lines, ["rm -rf"]); XCTAssertEqual(p.hiddenRemoved, 3)
    }
    func testNewlinesAreNotCountedAsHidden() { XCTAssertEqual(make("a\r\nb\tc\u{2028}d")?.hiddenRemoved, 0) }
    func testFoldedAndExpandedViews() {
        let p = make((1...30).map { "\($0). step" }.joined(separator: "\n"))!
        XCTAssertEqual(p.visible(expanded: false).shown.count, 5)
        XCTAssertEqual(p.visible(expanded: false).hidden, p.lines.count - 5)
        XCTAssertEqual(p.visible(expanded: true).shown.count, 16)
        XCTAssertTrue(p.canExpand)
        XCTAssertFalse(make("1. a\n2. b")!.canExpand)
    }
    func testLinesStayWithinBudgetAndHugePlanIsBounded() {
        let p = make(String(repeating: "word ", count: 100_000))!
        XCTAssertTrue(p.truncated)
        XCTAssertLessThanOrEqual(p.lines.joined().count, PlanProposal.maxChars)
        let many = make((1...5000).map { "line \($0)" }.joined(separator: "\n"))!
        XCTAssertLessThanOrEqual(many.lines.joined().count, PlanProposal.maxChars)
    }
}

final class PlanApprovalTests: XCTestCase {
    let input: [String: Any] = ["plan": "# P\n1. a\n2. b", "planFilePath": "/Users/me/.claude/plans/x.md"]
    let h = ApprovalTests()

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
    func testUnparsedPlanFallsBackButStillEchoes() {
        let m = h.model(); let (c, f) = h.pair()
        m.receiveApproval(req("ExitPlanMode", [:]), c)
        XCTAssertNil(m.pending[0].plan)
        m.resolve(m.pending[0].id, .allow)
        let r = h.reply(f)!
        XCTAssertEqual(r["behavior"] as? String, "allow"); XCTAssertNotNil(r["updatedInput"] as? [String: Any])
    }
    func testAlwaysIsRefusedAndNeverStored() {
        let store = AlwaysStore(url: nil)
        let m = NotchModel(always: store, log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")))
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
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")), clock: { t })
        let (c, _) = h.pair()
        m.receiveApproval(req(), c)
        m.pinRequest(m.pending[0].id)
        t = 100; m.sweep()
        XCTAssertFalse(m.folded)
    }
}
