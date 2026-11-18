import XCTest
@testable import ChippyCore

/// Issue #99: a hook written by an older Chippy is detected and migrated; custom values stay.
final class StaleHookTests: XCTestCase {
    private let bin = "/App/chippy-hook"

    private func settings(_ cmd: String, timeout: Int?) -> [String: Any] {
        var hook: [String: Any] = ["type": "command", "command": cmd]
        if let timeout { hook["timeout"] = timeout }
        return ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [hook]]]]]
    }

    private func hook(_ s: [String: Any]) -> [String: Any] {
        let e = ((s["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]])[0]
        return (e["hooks"] as! [[String: Any]])[0]
    }

    func testDefaultsAre60And120() {
        XCTAssertEqual(SettingsInstaller.defaultApprovalTimeout, 60)
        XCTAssertEqual(SettingsInstaller.maxApprovalTimeout, 120)
    }

    func testOldInstallIsStale() {
        let old = settings("\"\(bin)\" relay --timeout 20", timeout: 30)
        XCTAssertEqual(SettingsInstaller.staleness(old), [.missingQuestionFlag])
    }

    func testFreshInstallIsNotStale() {
        XCTAssertEqual(SettingsInstaller.staleness(SettingsInstaller.merged([:], binary: bin)), [])
    }

    func testShortHookTimeoutIsStaleEvenWithFlags() {
        let s = settings("\"\(bin)\" relay --timeout 60 --question-timeout 120", timeout: 125)
        XCTAssertEqual(SettingsInstaller.staleness(s), [.timeoutTooShort])
        XCTAssertEqual(SettingsInstaller.staleness(settings("\"\(bin)\" relay --timeout 60 --question-timeout 120", timeout: 130)), [])
    }

    func testMissingTimeoutKeyIsStale() {
        XCTAssertEqual(SettingsInstaller.staleness(settings("\"\(bin)\" relay --timeout 60 --question-timeout 120", timeout: nil)), [.timeoutTooShort])
    }

    func testNoChippyHookIsNotStale() {
        XCTAssertEqual(SettingsInstaller.staleness(settings("echo hi", timeout: 1)), [])
        XCTAssertEqual(SettingsInstaller.staleness([:]), [])
    }

    func testRepairMigratesOldDefaults() {
        let fixed = SettingsInstaller.merged(settings("\"\(bin)\" relay --timeout 20", timeout: 30), binary: bin)
        XCTAssertEqual(hook(fixed)["command"] as? String, "\"\(bin)\" relay --timeout 60 --question-timeout 120")
        XCTAssertEqual(hook(fixed)["timeout"] as? Int, 130)
        XCTAssertEqual(SettingsInstaller.staleness(fixed), [])
    }

    func testRepairKeepsCustomValues() {
        let fixed = SettingsInstaller.merged(settings("\"\(bin)\" relay --timeout 90", timeout: 30), binary: bin)
        XCTAssertEqual(hook(fixed)["command"] as? String, "\"\(bin)\" relay --timeout 90 --question-timeout 120")
        let custom = SettingsInstaller.merged(settings("\"\(bin)\" relay --timeout 20 --question-timeout 200", timeout: 40), binary: bin)
        XCTAssertEqual(hook(custom)["command"] as? String, "\"\(bin)\" relay --timeout 20 --question-timeout 200")
        XCTAssertEqual(hook(custom)["timeout"] as? Int, 210)
    }

    func testPatchedDeclinesStaleSoFullRenderRuns() {
        let text = "{\n  \"hooks\": {\n    \"PermissionRequest\": [ { \"matcher\": \"*\", \"hooks\": [ { \"type\": \"command\", \"command\": \"\\\"\(bin)\\\" relay --timeout 20\", \"timeout\": 30 } ] } ]\n  }\n}\n"
        XCTAssertNil(SettingsInstaller.patched(text, binary: bin, events: ["PermissionRequest"]))
    }
}
