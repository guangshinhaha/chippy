import XCTest
@testable import ChippyCore

final class ApprovalIntentTests: XCTestCase {
    let home = "/Users/me"
    func make(_ t: String, _ i: [String: Any]) -> ApprovalIntent? { ApprovalIntent.make(tool: t, input: i, home: home) }
    func text(_ t: String, _ i: [String: Any]) -> String? { make(t, i)?.text }
    func req(_ tool: String, _ input: [String: Any]) -> PendingRequest {
        PendingRequest(payload: HookPayload(json: try! JSONSerialization.data(withJSONObject: ["session_id": "s", "cwd": "/w", "hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input]))!)
    }

    func testBashDescriptionIsAttributedToAgent() {
        XCTAssertEqual(make("Bash", ["command": "npm i", "description": "Install dependencies"]), ApprovalIntent(text: "Install dependencies", fromAgent: true))
    }
    func testBashWithoutDescriptionHasNoIntent() {
        XCTAssertNil(make("Bash", ["command": "rm -rf build"]))
        XCTAssertNil(make("Bash", ["command": "x", "description": "  "]))
        XCTAssertNil(make("Bash", [:]))
    }
    func testMultilineDescriptionFlattens() {
        XCTAssertEqual(text("Bash", ["description": "Run tests\nthen\r\n  deploy"]), "Run tests then deploy")
    }
    func testFileToolsHaveNoIntentBecauseDetailIsTheirPath() {
        for t in ["Edit", "MultiEdit", "Write", "Read"] { XCTAssertNil(make(t, ["file_path": "/Users/me/a.swift"]), t) }
        XCTAssertEqual(req("Edit", ["file_path": "/Users/me/a.swift"]).detail, "/Users/me/a.swift")
        XCTAssertNil(req("Write", ["file_path": "/x"]).intent)
    }
    func testNotebookEditShowsFullPathWithTilde() {
        XCTAssertEqual(text("NotebookEdit", ["notebook_path": "/Users/me/n.ipynb"]), "Edit notebook ~/n.ipynb")
        XCTAssertEqual(text("NotebookEdit", ["notebook_path": "nb/n.ipynb"]), "Edit notebook nb/n.ipynb")
        XCTAssertFalse(make("NotebookEdit", ["notebook_path": "x"])!.fromAgent)
    }
    func testDisplayPathHomeAndRelative() {
        XCTAssertEqual(ApprovalIntent.displayPath("/Users/me/app/Foo.swift", home: home), "~/app/Foo.swift")
        XCTAssertEqual(ApprovalIntent.displayPath("/Users/me", home: home), "~")
        XCTAssertEqual(ApprovalIntent.displayPath("/Users/mex/a", home: home), "/Users/mex/a")
        XCTAssertEqual(ApprovalIntent.displayPath("notes/a.md", home: home), "notes/a.md")
    }
    func testVeryLongDirectoryKeepsFilenameWithinLimit() {
        let p = "/Users/me/" + (1...30).map { "dir\($0)" }.joined(separator: "/") + "/Important.swift"
        let t = ApprovalIntent.displayPath(p, home: home)
        XCTAssertTrue(t.contains("…"))
        XCTAssertTrue(t.hasSuffix("/Important.swift"))
        XCTAssertLessThanOrEqual(t.count, 60)
    }
    func testVeryLongFilenameIsTruncatedKeepingExtensionAndGraphemes() {
        let name = String(repeating: "naïve👨‍👩‍👧", count: 40) + ".swift"
        let t = ApprovalIntent.displayPath("/a/b/" + name, home: home)
        XCTAssertLessThanOrEqual(t.count, 60)
        XCTAssertTrue(t.hasSuffix(".swift"))
        XCTAssertTrue(t.contains("…"))
        XCTAssertTrue(t.contains("👨‍👩‍👧")) // family emoji never split
        let ext = String(repeating: "x", count: 100)
        XCTAssertLessThanOrEqual(ApprovalIntent.displayPath("/\(ext)", home: home).count, 60)
    }
    func testWebFetchShowsHostAndNothingWhenUnparseable() {
        XCTAssertEqual(text("WebFetch", ["url": "https://example.com/a?b=1"]), "Fetch example.com")
        XCTAssertNil(make("WebFetch", ["url": "not a url"]))
        XCTAssertNil(make("WebFetch", ["url": ""]))
    }
    func testWebSearchGlobGrep() {
        XCTAssertEqual(text("WebSearch", ["query": "swift concurrency"]), "Search the web for \"swift concurrency\"")
        XCTAssertEqual(text("Glob", ["pattern": "**/*.swift"]), "Find files matching **/*.swift")
        XCTAssertEqual(text("Grep", ["pattern": "TODO"]), "Search files for \"TODO\"")
    }
    func testUnmappedToolsHaveNoIntent() {
        XCTAssertNil(make("mcp__x__do", ["name": "thing"]))
        XCTAssertNil(make("AskUserQuestion", ["questions": []]))
        XCTAssertNil(req("AskUserQuestion", ["description": "x"]).intent)
    }
    func testIntentStripsBidiControlAndInvisibleScalars() {
        let evil = "Run \u{202E}tset\u{202C} tests\u{2066}\u{2069}\u{0007}\u{0000} now\u{200F}\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{180E}\u{2028}ok\u{2029}"
        XCTAssertEqual(text("Bash", ["description": evil]), "Run tset tests now ok")
    }
    func testRawDetailShowsHiddenScalarsVisibly() {
        let d = req("Bash", ["command": "ls \u{202E}gpj.exe\u{200B}\u{FEFF}\u{0007}\nrm x\tok"]).detail
        XCTAssertEqual(d, "ls <U+202E>gpj.exe<U+200B><U+FEFF><U+0007>\nrm x\tok")
        XCTAssertFalse(d.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x200B })
        XCTAssertEqual(ApprovalIntent.reveal("plain ☃ text"), "plain ☃ text")
    }
    func testVeryLongDescriptionIsCapped() {
        let r = text("Bash", ["description": String(repeating: "word ", count: 200)])!
        XCTAssertLessThanOrEqual(r.count, ApprovalIntent.maxLength)
        XCTAssertTrue(r.hasSuffix("…"))
    }
    func testHeadTailKeepsTheTail() {
        let d = ApprovalIntent.headTail(String(repeating: "a", count: 2000) + " | sh")
        XCTAssertTrue(d.hasSuffix("| sh"))
        XCTAssertTrue(d.hasPrefix("aaaa"))
        XCTAssertLessThan(d.count, 820)
        XCTAssertEqual(ApprovalIntent.headTail("short"), "short")
    }
    func testPreviewKeepsTailForAnyColumnWidthAndShapes() {
        XCTAssertEqual(ApprovalIntent.preview("npm install"), "npm install")
        let cmd = (1...40).map { "echo step-\($0)" }.joined(separator: " && ") + " | sh"
        for cols in [20, 40, 80] {
            let p = ApprovalIntent.preview(ApprovalIntent.headTail(cmd), columns: cols)
            let rows = p.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(rows.count, 6, "cols \(cols)")
            XCTAssertTrue(p.hasSuffix("| sh"), "cols \(cols)")
            XCTAssertTrue(p.hasPrefix("echo step-1 "))
            XCTAssertTrue(rows.allSatisfy { $0.count <= cols })
        }
        let multi = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\ncurl x | sh"
        XCTAssertTrue(ApprovalIntent.preview(multi).hasSuffix("curl x | sh"))
        XCTAssertTrue(ApprovalIntent.preview(String(repeating: "x", count: 5000) + " | sh").hasSuffix(" | sh"))
    }
    func testPendingRequestCarriesIntentAndTail() {
        XCTAssertEqual(req("Bash", ["command": "ls", "description": "List"]).intent?.fromAgent, true)
        XCTAssertTrue(req("Bash", ["command": String(repeating: "x", count: 3000) + " | sh"]).detail.hasSuffix("| sh"))
    }
}
