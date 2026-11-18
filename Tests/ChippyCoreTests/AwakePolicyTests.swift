import XCTest
@testable import ChippyCore

final class AwakePolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testWorkingAndNeedsYouHold() {
        XCTAssertTrue(AwakePolicy.shouldHold(state: .working, lastWorking: nil, now: t0))
        XCTAssertTrue(AwakePolicy.shouldHold(state: .needsYou, lastWorking: nil, now: t0))
    }
    func testIdleWithinDebounceHolds() {
        XCTAssertTrue(AwakePolicy.shouldHold(state: .idle, lastWorking: t0, now: t0.addingTimeInterval(29)))
    }
    func testIdleAfterDebounceReleases() {
        XCTAssertFalse(AwakePolicy.shouldHold(state: .idle, lastWorking: t0, now: t0.addingTimeInterval(30)))
        XCTAssertFalse(AwakePolicy.shouldHold(state: .done, lastWorking: t0, now: t0.addingTimeInterval(31)))
    }
    func testIdleNeverWorkedReleases() {
        XCTAssertFalse(AwakePolicy.shouldHold(state: .idle, lastWorking: nil, now: t0))
    }
    func testMarkerRecovery() {
        XCTAssertTrue(AwakePolicy.shouldClearOnLaunch(markerExists: true))
        XCTAssertFalse(AwakePolicy.shouldClearOnLaunch(markerExists: false))
    }
    func testBattery() {
        XCTAssertTrue(AwakePolicy.batteryTooLow(percent: 19, onAC: false))
        XCTAssertFalse(AwakePolicy.batteryTooLow(percent: 20, onAC: false))
        XCTAssertFalse(AwakePolicy.batteryTooLow(percent: 5, onAC: true))
        XCTAssertFalse(AwakePolicy.batteryTooLow(percent: nil, onAC: false))
    }
    func testLidDecision() {
        XCTAssertEqual(AwakePolicy.lidDecision(hold: true, lidModeEnabled: true, percent: 80, onAC: false), .on)
        XCTAssertEqual(AwakePolicy.lidDecision(hold: true, lidModeEnabled: true, percent: 10, onAC: false), .lowBattery)
        XCTAssertEqual(AwakePolicy.lidDecision(hold: false, lidModeEnabled: true, percent: 80, onAC: false), .off)
        XCTAssertEqual(AwakePolicy.lidDecision(hold: true, lidModeEnabled: false, percent: 80, onAC: false), .off)
    }

    // MARK: sudoers
    func testExactSudoersLine() {
        XCTAssertEqual(SudoersRule.line(user: "shin"),
            "shin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1")
    }
    func testRejectsInjectionUsers() {
        let bad = ["", "a b", "a,b", "a#b", "x\nALL ALL=(ALL) NOPASSWD: ALL", "a'b", "a\"b", "%admin", "!x", "-x", ".x",
                   "a;b", "a$(id)", "é", String(repeating: "a", count: 33)]
        for b in bad {
            XCTAssertFalse(SudoersRule.isValidUser(b), b)
            XCTAssertNil(SudoersRule.line(user: b))
            XCTAssertNil(SudoersRule.installScript(user: b))
        }
        for ok in ["shin", "guang.shin", "_svc", "a-b1"] { XCTAssertTrue(SudoersRule.isValidUser(ok), ok) }
    }
    func testRejectsSudoersAliasNames() {
        for b in ["ALL", "FOO_BAR", "NOPASSWD", "A", "X1"] {
            XCTAssertFalse(SudoersRule.isValidUser(b), b)
            XCTAssertNil(SudoersRule.line(user: b))
        }
        for ok in ["shin", "Shin", "aLL", "all", "fooBar"] { XCTAssertTrue(SudoersRule.isValidUser(ok), ok) }
    }
    func testInstallScriptRequiresExactVisudoOutput() {
        let s = SudoersRule.installScript(user: "shin")!
        XCTAssertTrue(s.contains("parsed OK"))
        XCTAssertTrue(s.range(of: "parsed OK")!.lowerBound < s.range(of: "/bin/mv")!.lowerBound)
    }
    func testLineOnlyAllowsPmsetDisablesleepZeroOne() {
        let l = SudoersRule.line(user: "shin")!
        XCTAssertEqual(l.components(separatedBy: "/usr/bin/pmset").count - 1, 2)
        XCTAssertFalse(l.contains("ALL=(ALL)"))
        XCTAssertFalse(l.contains("\n"))
        XCTAssertTrue(SudoersRule.isExpected(l + "\n", user: "shin"))
        XCTAssertFalse(SudoersRule.isExpected(l + "\nshin ALL=(ALL) NOPASSWD: ALL", user: "shin"))
        XCTAssertFalse(SudoersRule.isExpected(l, user: "other"))
    }
    func testInstallScriptValidatesBeforeMove() {
        let s = SudoersRule.installScript(user: "shin")!
        XCTAssertTrue(s.range(of: "visudo -cf")!.lowerBound < s.range(of: "/bin/mv")!.lowerBound)
        XCTAssertTrue(s.hasPrefix("set -e;"))
        XCTAssertTrue(s.contains("chmod 0440"))
        XCTAssertTrue(s.contains("/etc/sudoers.d/chippy-pmset"))
        XCTAssertEqual(SudoersRule.removeScript, "/bin/rm -f /etc/sudoers.d/chippy-pmset")
    }
    func testAppleScriptEscaping() {
        let a = SudoersRule.appleScript(forShell: #"echo "x" \n"#)
        XCTAssertEqual(a, #"do shell script "echo \"x\" \\n" with administrator privileges"#)
    }
}
