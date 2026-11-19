import XCTest
@testable import ChippyCore

/// Issue #129: the Orca worktree select is judged by the CLI's own answer, and its path comes from the running app.
final class OrcaCLITests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: path from the running app's bundle, never a literal

    func testCLIPathComesFromTheRunningAppBundle() {
        let app = URL(fileURLWithPath: "/Users/x/Apps/Orca Beta.app")
        XCTAssertEqual(OrcaCLI.cliURL(appBundleURL: app)?.path, "/Users/x/Apps/Orca Beta.app/Contents/Resources/bin/orca")
    }

    func testNoBundleURLMeansNoCLI() {
        XCTAssertNil(OrcaCLI.cliURL(appBundleURL: nil))
    }

    func testArgumentsSelectTheWorktreeByPathAsJSON() {
        XCTAssertEqual(OrcaCLI.arguments(cwd: "/Users/x/wt/chippy"),
                       ["worktree", "activate", "--worktree", "path:/Users/x/wt/chippy", "--json"])
    }

    // MARK: reading the CLI's answer

    func testExitZeroWithOkTrueIsSelected() {
        XCTAssertEqual(OrcaCLI.interpret(exitStatus: 0, stdout: json(#"{"id":"1","ok":true,"result":{}}"#)), .selected)
    }

    func testNonZeroExitFails() {
        guard case .failed = OrcaCLI.interpret(exitStatus: 1, stdout: json(#"{"ok":true}"#)) else { return XCTFail("non-zero exit must fail") }
    }

    func testOkFalseFailsEvenWithExitZero() {
        guard case .failed = OrcaCLI.interpret(exitStatus: 0, stdout: json(#"{"ok":false,"error":{"code":"runtime_unavailable"}}"#)) else { return XCTFail("ok:false must fail") }
    }

    func testExitZeroWithUnreadableOutputIsUnconfirmed() {
        XCTAssertEqual(OrcaCLI.interpret(exitStatus: 0, stdout: json("")), .unconfirmed)
        XCTAssertEqual(OrcaCLI.interpret(exitStatus: 0, stdout: json("done")), .unconfirmed)
        XCTAssertEqual(OrcaCLI.interpret(exitStatus: 0, stdout: json(#"{"result":{}}"#)), .unconfirmed)
    }

    // MARK: what the jump reports

    func testSelectedKeepsTheAppVerdict() {
        for v: ActivationOutcome.Verdict in [.landed, .landedUnverified] {
            XCTAssertEqual(OrcaCLI.finalVerdict(v, select: .selected), v)
        }
    }

    func testUnconfirmedDowngradesLandedToUnverified() {
        XCTAssertEqual(OrcaCLI.finalVerdict(.landed, select: .unconfirmed), .landedUnverified)
        XCTAssertEqual(OrcaCLI.finalVerdict(.landedUnverified, select: .unconfirmed), .landedUnverified)
    }

    func testFailedSelectIsNeverLanded() {
        for v: ActivationOutcome.Verdict in [.landed, .landedUnverified] {
            XCTAssertEqual(OrcaCLI.finalVerdict(v, select: .failed("cli missing")), .workspaceNotSelected)
        }
    }

    func testAppLevelFailuresPassThrough() {
        XCTAssertEqual(OrcaCLI.finalVerdict(.notFrontmost, select: .selected), .notFrontmost)
        XCTAssertEqual(OrcaCLI.finalVerdict(.offSpace, select: .failed("x")), .offSpace)
    }

    // MARK: sounds (#78): Orca frontmost is muted

    func testSoundsAreMutedWhileOrcaIsFrontmost() {
        let orca = HostInfo(pid: 100, bundle: OrcaCLI.bundleId, tty: nil, cwd: "/wt/chippy")
        let frontmost = SoundPolicy.isHostFrontmost(host: orca, frontmostPid: 100, frontmostBundle: OrcaCLI.bundleId)
        XCTAssertTrue(frontmost)
        for kind in [SoundKind.needsYou, .done] {
            XCTAssertFalse(SoundPolicy.shouldPlay(kind: kind, enabled: true, hostFrontmost: frontmost, quiet: false, lastPlayed: nil, now: Date()))
        }
    }

    func testSoundsPlayWhenAnotherAppIsFrontmost() {
        let orca = HostInfo(pid: 100, bundle: OrcaCLI.bundleId, tty: nil)
        let frontmost = SoundPolicy.isHostFrontmost(host: orca, frontmostPid: 7, frontmostBundle: "com.apple.Safari")
        XCTAssertFalse(frontmost)
        XCTAssertTrue(SoundPolicy.shouldPlay(kind: .needsYou, enabled: true, hostFrontmost: frontmost, quiet: false, lastPlayed: nil, now: Date()))
    }
}
