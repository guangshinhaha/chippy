import XCTest
@testable import ChippyCore

/// Review follow-ups on #99: default fallback, NSNumber timeouts, missing PermissionRequest, transient paths.
final class StaleHookFollowUpTests: XCTestCase {
    private let bin = "/App/chippy-hook"
    private func s(_ cmd: String, timeout: Any) -> [String: Any] {
        ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [["type": "command", "command": cmd, "timeout": timeout]]]]]]
    }

    func testMissingApprovalFlagUsesCurrentDefault() {
        // need = max(60, 30) + 10 = 70
        XCTAssertEqual(SettingsInstaller.staleness(s("\"\(bin)\" relay --question-timeout 30", timeout: 45)), [.timeoutTooShort])
        XCTAssertEqual(SettingsInstaller.staleness(s("\"\(bin)\" relay --question-timeout 30", timeout: 70)), [])
    }

    func testDoubleTimeoutCountsAsInt() {
        let cmd = "\"\(bin)\" relay --timeout 60 --question-timeout 120"
        XCTAssertEqual(SettingsInstaller.staleness(s(cmd, timeout: 130.0)), [])
        XCTAssertEqual(SettingsInstaller.staleness(s(cmd, timeout: 125.0)), [.timeoutTooShort])
    }

    func testOtherEventsWithoutPermissionRequestIsStale() {
        let o: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "\"\(bin)\" relay"]]]]]]
        XCTAssertEqual(SettingsInstaller.staleness(o), [.missingPermissionRequest])
    }

    func testTransientPaths() {
        let t = "/var/folders/ab/T/"
        XCTAssertTrue(SettingsInstaller.isTransientPath("/private/var/folders/ab/AppTranslocation/X/d/Chippy.app/Contents/MacOS/chippy-hook", tempDir: t))
        XCTAssertFalse(SettingsInstaller.isTransientPath("/Volumes/Work/Chippy.app/Contents/MacOS/chippy-hook", tempDir: t))
        XCTAssertTrue(SettingsInstaller.isTransientPath("/var/folders/ab/T/x/chippy-hook", tempDir: t))
        XCTAssertTrue(SettingsInstaller.isTransientPath("/tmp/x/chippy-hook", tempDir: t))
        XCTAssertFalse(SettingsInstaller.isTransientPath("/Applications/Chippy.app/Contents/MacOS/chippy-hook", tempDir: t))
        XCTAssertFalse(SettingsInstaller.isTransientPath("/Users/me/chippy/.build/debug/chippy-hook", tempDir: t))
        XCTAssertFalse(SettingsInstaller.isTransientPath("/Users/me/chippy/build/Chippy.app/Contents/MacOS/chippy-hook", tempDir: t))
    }
}
