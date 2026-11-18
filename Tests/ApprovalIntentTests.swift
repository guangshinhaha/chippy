import XCTest
@testable import ChippyCore

final class ApprovalIntentTests: XCTestCase {
    func line(_ t: String, _ i: [String: Any]) -> String { ApprovalIntent.line(tool: t, input: i) }

    func testBashWithDescriptionUsesIt() {
        XCTAssertEqual(line("Bash", ["command": "npm i", "description": "Install dependencies"]), "Install dependencies")
    }
    func testBashWithoutDescriptionDoesNotInventAReason() {
        XCTAssertEqual(line("Bash", ["command": "rm -rf build"]), "Run a shell command")
    }
    func testEditAndWriteNameTheFile() {
        XCTAssertEqual(line("Edit", ["file_path": "/w/Sources/Foo.swift"]), "Edit Foo.swift")
        XCTAssertEqual(line("Write", ["file_path": "notes.md"]), "Write notes.md")
    }
    func testWebFetch() {
        XCTAssertEqual(line("WebFetch", ["url": "https://example.com/a"]), "Fetch https://example.com/a")
    }
    func testUnknownTool() {
        XCTAssertEqual(line("mcp__x__do", ["name": "thing"]), "Use mcp__x__do: thing")
        XCTAssertEqual(line("mcp__x__do", ["opaque": 1]), "Use mcp__x__do")
    }
    func testVeryLongInputIsCappedToOneLine() {
        let r = line("Bash", ["description": String(repeating: "word\n", count: 200)])
        XCTAssertLessThanOrEqual(r.count, ApprovalIntent.maxLength)
        XCTAssertFalse(r.contains("\n"))
        XCTAssertTrue(r.hasSuffix("…"))
    }
    func testEmptyInput() {
        XCTAssertEqual(line("Bash", [:]), "Run a shell command")
        XCTAssertEqual(line("Edit", [:]), "Edit a file")
        XCTAssertEqual(line("Bash", ["description": "  "]), "Run a shell command")
    }
    func testPendingRequestCarriesIntent() {
        let p = HookPayload(json: try! JSONSerialization.data(withJSONObject: ["session_id": "s", "cwd": "/w", "hook_event_name": "PermissionRequest", "tool_name": "Edit", "tool_input": ["file_path": "/w/A.swift"]]))!
        XCTAssertEqual(PendingRequest(payload: p).intent, "Edit A.swift")
    }
}
