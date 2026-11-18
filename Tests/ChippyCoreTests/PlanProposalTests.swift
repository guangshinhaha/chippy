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
        XCTAssertEqual(plan?.text, "## Plan 1. Step one 2. Step two")
        XCTAssertEqual(plan?.fileName, "example-plan.md")
        XCTAssertEqual(plan?.truncated, false)
    }
    func testEmptyInputFallsBack() { XCTAssertNil(PlanProposal.make(tool: "ExitPlanMode", input: [:])) }
    func testNonStringPlanFallsBack() { XCTAssertNil(PlanProposal.make(tool: "ExitPlanMode", input: ["plan": 5])) }
    func testWrongToolFallsBack() { XCTAssertNil(PlanProposal.make(tool: "Bash", input: ["plan": "x"])) }
    func testHiddenCharactersStripped() {
        XCTAssertEqual(PlanProposal.make(tool: "ExitPlanMode", input: ["plan": "a\u{202E}b\u{200B}c"])?.text, "abc")
        XCTAssertNil(PlanProposal.make(tool: "ExitPlanMode", input: ["plan": "\u{200B}\n "]))
    }
    func testCapped() {
        let plan = PlanProposal.make(tool: "ExitPlanMode", input: ["plan": String(repeating: "x", count: 5000)])
        XCTAssertEqual(plan?.text.count, PlanProposal.maxChars)
        XCTAssertEqual(plan?.truncated, true)
    }
}
