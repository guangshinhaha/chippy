import XCTest
@testable import ChippyCore

/// Issue #136: each verdict has its own words on the Open button, and a process that holds stdout open cannot stall a jump.
final class JumpFeedbackTests: XCTestCase {
    func testWorkspaceNotSelectedSaysTheAppCameForwardButTheWorkspaceWasNot() {
        let t = JumpFeedback.text(for: .workspaceNotSelected, appName: "Orca")
        XCTAssertEqual(t?.title, "Not selected")
        XCTAssertTrue(t?.help.contains("Orca came forward") ?? false)
        XCTAssertTrue(t?.help.contains("select this session's workspace") ?? false)
        XCTAssertNotEqual(t?.title, JumpFeedback.text(for: .notFrontmost, appName: "Orca")?.title, "its own wording, not Couldn't open")
        XCTAssertFalse(t?.help.contains("bring the app forward") ?? true, "the app did come forward")
    }

    func testEachFailureHasItsOwnWords() {
        let all: [ActivationOutcome.Verdict] = [.notFrontmost, .offSpace, .workspaceNotSelected]
        let titles = all.compactMap { JumpFeedback.text(for: $0, appName: "X")?.title }
        XCTAssertEqual(titles.count, 3)
        XCTAssertEqual(Set(titles).count, 3)
    }

    func testLandedAndUnverifiedShowNothing() {
        XCTAssertNil(JumpFeedback.text(for: .landed, appName: "X"))
        XCTAssertNil(JumpFeedback.text(for: .landedUnverified, appName: "X"), "an unconfirmed jump counts as opened: no warning")
    }

    // MARK: the select ends on process exit, with a cap

    private let sh = URL(fileURLWithPath: "/bin/sh")

    func testAnOkAnswerIsReadEvenWhenAChildKeepsStdoutOpen() {
        let t0 = Date()
        let r = HostProcess.run(sh, ["-c", #"sleep 20 & echo '{"ok":true}'"#], timeout: 5)
        XCTAssertEqual(r, .selected)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "ends when the process exits, not when stdout closes")
    }

    func testAProcessThatRunsPastTheCapIsTerminatedAndTimesOut() {
        let t0 = Date()
        let r = HostProcess.run(sh, ["-c", "sleep 20"], timeout: 1)
        XCTAssertEqual(r, .failed("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6)
    }

    func testAProcessHoldingStdoutOpenPastTheCapStillTimesOut() {
        let t0 = Date()
        let r = HostProcess.run(sh, ["-c", "sleep 20 & sleep 20"], timeout: 1)
        XCTAssertEqual(r, .failed("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6)
    }

    func testAnAnswerWrittenInPiecesJustBeforeExitIsNeverSplitOrLost() {
        for i in 0..<100 {
            XCTAssertEqual(HostProcess.run(sh, ["-c", #"printf '{"ok":'; printf 'true}'"#], timeout: 5), .selected, "run \(i)")
        }
    }

    func testExitCodeAndUnreadableAnswerStillMapThroughInterpret() {
        XCTAssertEqual(HostProcess.run(sh, ["-c", "exit 3"], timeout: 5), .failed("exit 3"))
        XCTAssertEqual(HostProcess.run(sh, ["-c", "echo not-json"], timeout: 5), .unconfirmed)
        XCTAssertEqual(HostProcess.run(URL(fileURLWithPath: "/nonexistent/cli"), [], timeout: 5), .failed("could not run the host CLI"))
    }
}
