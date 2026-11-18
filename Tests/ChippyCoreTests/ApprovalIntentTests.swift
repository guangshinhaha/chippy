import XCTest
@testable import ChippyCore

final class ApprovalIntentTests: XCTestCase {
    let home = "/Users/me"
    func make(_ t: String, _ i: [String: Any]) -> ApprovalIntent? { ApprovalIntent.make(tool: t, input: i, home: home) }
    func text(_ t: String, _ i: [String: Any]) -> String? { make(t, i)?.text }

    func testBashDescriptionIsAttributedToAgent() {
        let i = make("Bash", ["command": "npm i", "description": "Install dependencies"])
        XCTAssertEqual(i, ApprovalIntent(text: "Install dependencies", fromAgent: true))
    }
    func testBashWithoutDescriptionHasNoIntent() {
        XCTAssertNil(make("Bash", ["command": "rm -rf build"]))
        XCTAssertNil(make("Bash", ["command": "x", "description": "  "]))
        XCTAssertNil(make("Bash", [:]))
    }
    func testMultilineDescriptionFlattens() {
        XCTAssertEqual(text("Bash", ["description": "Run tests\nthen\r\n  deploy"]), "Run tests then deploy")
    }
    func testFileToolsShowFullPathWithHomeAsTilde() {
        XCTAssertEqual(text("Edit", ["file_path": "/Users/me/app/Sources/Foo.swift"]), "Edit ~/app/Sources/Foo.swift")
        XCTAssertEqual(text("MultiEdit", ["file_path": "/etc/hosts"]), "Edit /etc/hosts")
        XCTAssertEqual(text("Write", ["file_path": "/Users/me"]), "Write ~")
        XCTAssertEqual(text("Read", ["file_path": "/Users/mex/a"]), "Read /Users/mex/a") // not a home prefix
        XCTAssertEqual(text("NotebookEdit", ["notebook_path": "/Users/me/n.ipynb"]), "Edit notebook ~/n.ipynb")
        XCTAssertFalse(make("Write", ["file_path": "/x"])!.fromAgent)
    }
    func testRelativePathsKeptAsIs() {
        XCTAssertEqual(text("Write", ["file_path": "notes/a.md"]), "Write notes/a.md")
    }
    func testVeryLongPathMiddleTruncatesKeepingFilename() {
        let p = "/Users/me/" + (1...30).map { "dir\($0)" }.joined(separator: "/") + "/Important.swift"
        let t = text("Edit", ["file_path": p])!
        XCTAssertTrue(t.contains("…"))
        XCTAssertTrue(t.hasSuffix("/Important.swift"))
        XCTAssertLessThanOrEqual(t.count, 70)
    }
    func testWebFetchShowsHost() {
        XCTAssertEqual(text("WebFetch", ["url": "https://example.com/a?b=1"]), "Fetch example.com")
        XCTAssertEqual(text("WebFetch", ["url": "not a url"]), "Fetch not a url")
    }
    func testWebSearchGlobGrep() {
        XCTAssertEqual(text("WebSearch", ["query": "swift concurrency"]), "Search the web for \"swift concurrency\"")
        XCTAssertEqual(text("Glob", ["pattern": "**/*.swift"]), "Find files matching **/*.swift")
        XCTAssertEqual(text("Grep", ["pattern": "TODO"]), "Search files for \"TODO\"")
    }
    func testUnmappedToolsHaveNoIntent() {
        XCTAssertNil(make("mcp__x__do", ["name": "thing"]))
        XCTAssertNil(make("AskUserQuestion", ["questions": []]))
        XCTAssertNil(make("Edit", [:]))
        XCTAssertNil(make("WebFetch", ["url": ""]))
    }
    func testBidiAndControlCharactersAreStripped() {
        let evil = "Run \u{202E}tset\u{202C} tests\u{2066}\u{2069}\u{0007}\u{0000} now\u{200F}"
        XCTAssertEqual(text("Bash", ["description": evil]), "Run tset tests now")
        XCTAssertEqual(text("Edit", ["file_path": "/a/\u{202E}gpj.exe"]), "Edit /a/gpj.exe")
    }
    func testVeryLongDescriptionIsCapped() {
        let r = text("Bash", ["description": String(repeating: "word ", count: 200)])!
        XCTAssertLessThanOrEqual(r.count, ApprovalIntent.maxLength)
        XCTAssertTrue(r.hasSuffix("…"))
    }
    func testHeadTailKeepsTheTail() {
        let cmd = String(repeating: "a", count: 2000) + " | sh"
        let d = ApprovalIntent.headTail(cmd)
        XCTAssertTrue(d.hasSuffix("| sh"))
        XCTAssertTrue(d.hasPrefix("aaaa"))
        XCTAssertLessThan(d.count, 820)
        XCTAssertEqual(ApprovalIntent.headTail("short"), "short")
    }
    func testPreviewKeepsHeadAndTailWithinSixRows() {
        XCTAssertEqual(ApprovalIntent.preview("npm install"), "npm install")
        let cmd = (1...40).map { "echo step-\($0)" }.joined(separator: " && ") + " | sh"
        let p = ApprovalIntent.preview(ApprovalIntent.headTail(cmd))
        let rows = p.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(rows.count, 6)
        XCTAssertTrue(p.hasSuffix("| sh"))
        XCTAssertTrue(p.hasPrefix("echo step-1 "))
        XCTAssertTrue(rows.allSatisfy { $0.count <= 44 })
        let multi = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\ncurl x | sh"
        XCTAssertTrue(ApprovalIntent.preview(multi).hasSuffix("curl x | sh"))
    }
    func testPendingRequestCarriesIntentAndTail() {
        func req(_ tool: String, _ input: [String: Any]) -> PendingRequest {
            PendingRequest(payload: HookPayload(json: try! JSONSerialization.data(withJSONObject: ["session_id": "s", "cwd": "/w", "hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input]))!)
        }
        XCTAssertEqual(req("Bash", ["command": "ls", "description": "List"]).intent?.fromAgent, true)
        XCTAssertNil(req("AskUserQuestion", ["description": "x"]).intent)
        XCTAssertTrue(req("Bash", ["command": String(repeating: "x", count: 3000) + " | sh"]).detail.hasSuffix("| sh"))
    }
}
