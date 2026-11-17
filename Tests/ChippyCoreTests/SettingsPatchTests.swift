import XCTest
@testable import ChippyCore

final class SettingsPatchTests: XCTestCase {
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

    func testNoHooksKeyKeepsEverythingElseVerbatim() throws {
        let text = "{\n  \"z\": 1,\n  \"env\": { \"A\": \"b\" }\n}\n"
        let out = try check(text)
        XCTAssertTrue(out.hasPrefix("{\n  \"z\": 1,\n  \"env\": { \"A\": \"b\" }"), out)
    }

    func testExistingEventArrayGetsAppendedAndOthersUntouched() throws {
        let text = """
        {
          "hooks": {
            "Stop": [
              { "matcher": "*", "hooks": [ { "type": "command", "command": "echo \\"x\\" }" } ] }
            ]
          },
          "model": "opus"
        }
        """
        let out = try check(text)
        XCTAssertTrue(out.contains("\"model\": \"opus\""))
        XCTAssertTrue(out.contains("echo \\\"x\\\" }"))
    }

    func testEmptyHooksObjectAndEmptyEventArray() throws {
        _ = try check("{\n  \"hooks\": {}\n}\n")
        _ = try check("{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n")
    }

    func testSinglePermissionTimeoutIsLargerThanOurs() throws {
        let out = try check("{\n  \"a\": 1\n}\n")
        XCTAssertTrue(out.contains("\"timeout\": 30"))
    }

    func testIdempotent() throws {
        let once = try check("{\n  \"a\": 1\n}\n")
        let old = try JSONSerialization.jsonObject(with: Data(once.utf8)) as! [String: Any]
        let again = SettingsInstaller.merged(old, binary: bin)
        XCTAssertTrue(NSDictionary(dictionary: again).isEqual(to: old))
        XCTAssertEqual(SettingsInstaller.patched(once, binary: bin), once)
    }

    func testSingleLineLayoutDeclinesSoCallerFallsBack() {
        XCTAssertNil(SettingsInstaller.patched("{\"a\":1}", binary: bin))
    }
}
