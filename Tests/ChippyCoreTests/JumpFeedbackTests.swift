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

    func testPanelRowsGetTheSameWordsAsTheButton() {
        XCTAssertEqual(JumpFeedback.text(for: .workspaceNotSelected, appName: "Orca")?.line, "Orca opened, but its workspace wasn't selected")
        XCTAssertEqual(JumpFeedback.text(for: .notFrontmost, appName: "Orca")?.line, "Couldn't open Orca")
        XCTAssertEqual(JumpFeedback.text(for: .offSpace, appName: "Orca")?.line, "Orca is on another Space")
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

    /// The process behind a timed-out select must be gone when `run` returns, not left running in the background.
    private func assertGoneAfterTimeout(_ script: String, within seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) throws {
        let pidFile = scratchURL("chippy-136-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let t0 = Date()
        let r = HostProcess.run(sh, ["-c", "echo $$ > '\(pidFile.path)'; \(script)"], timeout: 1)
        XCTAssertEqual(r, .failed("timed out"), file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(t0), seconds, file: file, line: line)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)), file: file, line: line)
        XCTAssertEqual(kill(pid, 0), -1, "the timed-out process is dead", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }

    func testATimedOutProcessIsTerminated() throws { try assertGoneAfterTimeout("exec sleep 20", within: 2) }

    func testAProcessThatIgnoresTermIsStillKilled() throws { try assertGoneAfterTimeout("trap '' TERM; sleep 20", within: 4) }

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
