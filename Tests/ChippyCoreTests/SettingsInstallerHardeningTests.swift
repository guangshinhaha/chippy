import XCTest
@testable import ChippyCore

/// Issue #19: CRLF, duplicate keys, loose installed check, escaped keys, empty-array indent.
final class SettingsInstallerHardeningTests: XCTestCase {
    private let bin = "/App/chippy-hook"

    /// The patch must parse to exactly what the full merge would produce.
    private func check(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let old = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let want = SettingsInstaller.merged(old, binary: bin)
        let patched = try XCTUnwrap(SettingsInstaller.patched(text, binary: bin), file: file, line: line)
        let got = try JSONSerialization.jsonObject(with: Data(patched.utf8)) as! [String: Any]
        XCTAssertTrue(NSDictionary(dictionary: want).isEqual(to: got), patched, file: file, line: line)
        return patched
    }

    func testCRLFInputGetsCRLFOutputWithNoBareLF() throws {
        let withEmptyEvent = try check("{\r\n  \"a\": 1,\r\n  \"hooks\": {\r\n    \"Stop\": []\r\n  }\r\n}\r\n")
        let noHooks = try check("{\r\n  \"a\": 1\r\n}\r\n")
        for out in [withEmptyEvent, noHooks] {
            XCTAssertTrue(out.contains("\r\n"))
            XCTAssertFalse(out.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "bare LF in output")
        }
    }

    func testDuplicateTopLevelHooksKeyIsReported() {
        XCTAssertEqual(SettingsInstaller.duplicateKeys("{\n  \"hooks\": {},\n  \"hooks\": {}\n}\n"), ["hooks"])
    }

    func testDuplicateEventKeyInsideHooksIsReported() {
        XCTAssertEqual(SettingsInstaller.duplicateKeys("{\n  \"hooks\": {\n    \"Stop\": [],\n    \"Stop\": []\n  }\n}\n"), ["Stop"])
        XCTAssertEqual(SettingsInstaller.duplicateKeys("{\n  \"hooks\": { \"Stop\": [] }\n}\n"), [])
    }

    func testEntryMentioningChippyHookInAnotherFieldStillGetsOurEntry() throws {
        let text = "{\n  \"hooks\": {\n    \"Stop\": [\n"
            + "      { \"matcher\": \"*\", \"description\": \"not chippy-hook\", \"hooks\": [ { \"type\": \"command\", \"command\": \"echo hi\" } ] }\n"
            + "    ]\n  }\n}\n"
        let out = try check(text)
        XCTAssertTrue(out.contains("\"command\": \"\\\"/App/chippy-hook\\\" relay\""), out)
        // The reusable matcher (used by merged(), the patcher and #34): command strings only.
        XCTAssertFalse(SettingsInstaller.hasChippyHook([["description": "chippy-hook", "hooks": [["command": "echo"]]]]))
        XCTAssertTrue(SettingsInstaller.hasChippyHook([["hooks": [["command": "\"/x/chippy-hook\" relay"]]]]))
        let merged = SettingsInstaller.merged(["hooks": ["Stop": [["description": "chippy-hook", "hooks": [["command": "echo"]]]]]], binary: bin)
        XCTAssertEqual(((merged["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count, 2)
    }

    func testEscapedHooksKeyPatchesInsteadOfFallingBack() throws {
        let out = try check("{\n  \"\\u0068ooks\": {\n    \"Stop\": []\n  }\n}\n")
        XCTAssertFalse(out.contains("\n  \"hooks\":"), "must not add a second top-level hooks key: \(out)")
        XCTAssertTrue(out.hasPrefix("{\n  \"\\u0068ooks\": {"))
    }

    func testEmptyEventArrayIndentsFromTheEventKeyLine() throws {
        let text = "{\n  \"hooks\": {\n      \"Stop\": []\n  }\n}\n"
        let out = try XCTUnwrap(SettingsInstaller.patched(text, binary: bin, events: ["Stop"]))
        let want = [
            "{",
            "  \"hooks\": {",
            "      \"Stop\": [",
            "        {",
            "          \"matcher\": \"*\",",
            "          \"hooks\": [",
            "            { \"type\": \"command\", \"command\": \"\\\"/App/chippy-hook\\\" relay\" }",
            "          ]",
            "        }",
            "      ]",
            "  }",
            "}",
            "",
        ].joined(separator: "\n")
        XCTAssertEqual(out, want)
    }
}
