import XCTest
@testable import ChippyCore

/// Fixture follows the documented ExitPlanMode tool_input (code.claude.com/docs/en/hooks). Doc-derived, redacted, not a live capture.
final class PlanProposalTests: XCTestCase {
    static let fixture = """
    {"session_id":"s","cwd":"/w","permission_mode":"plan","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode",
     "tool_input":{"plan":"## Plan\\n1. Step one\\n2. Step two","planFilePath":"/Users/me/.claude/plans/example-plan.md"}}
    """

    func testParsesFixture() {
        let p = HookPayload(json: Data(Self.fixture.utf8))!
        let plan = PlanProposal.make(tool: p.toolName ?? "", input: p.toolInput)
        XCTAssertEqual(plan?.title, "Plan"); XCTAssertEqual(plan?.lines, ["1. Step one", "2. Step two"])
        XCTAssertEqual(plan?.fileName, "example-plan.md")
        XCTAssertEqual(plan?.truncated, false)
    }
    func testEmptyInputFallsBack() { XCTAssertNil(PlanProposal.make(tool: "ExitPlanMode", input: [:])) }
    func testNonStringPlanFallsBack() { XCTAssertNil(PlanProposal.make(tool: "ExitPlanMode", input: ["plan": 5])) }
    func testWrongToolFallsBack() { XCTAssertNil(PlanProposal.make(tool: "Bash", input: ["plan": "x"])) }
    func testHiddenCharactersStripped() {
        XCTAssertEqual(PlanProposal.make(tool: "ExitPlanMode", input: ["plan": "a\u{202E}b\u{200B}c"])?.lines, ["abc"])
        XCTAssertNil(PlanProposal.make(tool: "ExitPlanMode", input: ["plan": "\u{200B}\n "]))
    }
    func testCapped() {
        let plan = PlanProposal.make(tool: "ExitPlanMode", input: ["plan": String(repeating: "x", count: 5000)])
        XCTAssertEqual(plan?.lines.joined().count, PlanProposal.rowChars)
        XCTAssertEqual(plan?.truncated, true)
    }
    func testPlanCannotForgeMarkerSymbol() {
        let plan = PlanProposal.make(tool: "ExitPlanMode", input: ["plan": "# \u{22EF} T \u{22EF}\n\u{22EF} plan continues in the terminal \u{22EF}"])
        XCTAssertFalse((plan?.lines ?? []).joined().contains("\u{22EF}"))
        XCTAssertFalse((plan?.title ?? "").contains("\u{22EF}"))
        XCTAssertEqual(plan?.lines, ["<U+22EF> plan continues in the terminal <U+22EF>"])
    }
    func testHiddenCountIsWithinDisplayedText() {
        let plan = PlanProposal.make(tool: "ExitPlanMode", input: ["plan": "a" + String(repeating: " ", count: 150) + "\u{202E}evil"])
        XCTAssertEqual(plan?.lines, ["a evil"])
        XCTAssertEqual(plan?.hiddenRemoved(expanded: true), 1)
    }
    func testHiddenBeyondDisplayedClipNotCounted() {
        let plan = PlanProposal.make(tool: "ExitPlanMode", input: ["plan": String(repeating: "x", count: 200) + "\u{202E}"])
        XCTAssertEqual(plan?.hiddenRemoved(expanded: true), 0)
    }
}
