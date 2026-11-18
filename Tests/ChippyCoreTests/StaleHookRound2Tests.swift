import XCTest
@testable import ChippyCore

/// Review round 2 on #99: legacy 20 with the question flag, clamped compare, NSNumber in the patcher.
final class StaleHookRound2Tests: XCTestCase {
    private let bin = "/App/chippy-hook"
    private func s(_ cmd: String, timeout: Any) -> [String: Any] {
        ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [["type": "command", "command": cmd, "timeout": timeout]]]]]]
    }
    private func firstHook(_ m: [String: Any]) -> [String: Any]? {
        (((m["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
    }

    func testPreviousReleaseInstallIsLegacy() {
        let o = s("\"\(bin)\" relay --timeout 20 --question-timeout 120", timeout: 130)
        XCTAssertEqual(SettingsInstaller.staleness(o), [.legacyApprovalTimeout])
        let m = SettingsInstaller.merged(o, binary: bin)
        XCTAssertEqual(firstHook(m)?["command"] as? String, "\"\(bin)\" relay --timeout 60 --question-timeout 120")
        XCTAssertEqual(firstHook(m)?["timeout"] as? Int, 130)
        XCTAssertEqual(SettingsInstaller.staleness(m), [])
    }

    func testCustomTimeoutKept() {
        let o = s("\"\(bin)\" relay --timeout 30 --question-timeout 120", timeout: 130)
        XCTAssertEqual(SettingsInstaller.staleness(o), [])
        XCTAssertEqual(firstHook(SettingsInstaller.merged(o, binary: bin))?["command"] as? String, "\"\(bin)\" relay --timeout 30 --question-timeout 120")
    }

    func testStalenessComparesClampedValues() {
        // The relay clamps 500/900 to 120/300, so it needs 310.
        let cmd = "\"\(bin)\" relay --timeout 500 --question-timeout 900"
        XCTAssertEqual(SettingsInstaller.staleness(s(cmd, timeout: 200)), [.timeoutTooShort])
        XCTAssertEqual(SettingsInstaller.staleness(s(cmd, timeout: 310.0)), [])
    }
}
