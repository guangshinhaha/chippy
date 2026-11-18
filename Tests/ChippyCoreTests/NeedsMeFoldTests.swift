import Darwin
import XCTest
@testable import ChippyCore

final class NeedsMeFoldTests: XCTestCase {
    // MARK: pure fold logic

    func testFoldsAtExactlyFifteenSeconds() {
        var f = NeedsMeFold()
        f.arrive(now: 100, hovering: false, engaged: false)
        XCTAssertFalse(f.isDue(now: 114.999))
        XCTAssertTrue(f.isDue(now: 115))
    }

    func testHoverPausesAndResumesWithRemainingTime() {
        var f = NeedsMeFold()
        f.arrive(now: 0, hovering: false, engaged: false)
        f.setHover(true, now: 10)
        XCTAssertFalse(f.isDue(now: 500))        // held while hovered
        f.setHover(false, now: 500)
        XCTAssertFalse(f.isDue(now: 504.9))      // the 5s that were left
        XCTAssertTrue(f.isDue(now: 505))
    }

    func testArrivingUnderTheCursorStartsPaused() {
        var f = NeedsMeFold()
        f.arrive(now: 0, hovering: true, engaged: false)
        XCTAssertFalse(f.isDue(now: 100))
        f.setHover(false, now: 100)
        XCTAssertFalse(f.isDue(now: 114.9)); XCTAssertTrue(f.isDue(now: 115))
    }

    func testNewRequestRestartsTheTimer() {
        var f = NeedsMeFold()
        f.arrive(now: 0, hovering: false, engaged: false)
        f.arrive(now: 12, hovering: false, engaged: false)
        XCTAssertFalse(f.isDue(now: 26.9)); XCTAssertTrue(f.isDue(now: 27))
    }

    func testPinnedNeverFoldsAndSurvivesANewRequest() {
        var f = NeedsMeFold()
        f.arrive(now: 0, hovering: false, engaged: false)
        f.pin()
        XCTAssertFalse(f.isDue(now: 1000))
        f.arrive(now: 5, hovering: false, engaged: false)   // a second request must not fold the card the user opened
        XCTAssertFalse(f.isDue(now: 1000))
        f.reset()
        f.arrive(now: 2000, hovering: false, engaged: false)
        XCTAssertTrue(f.isDue(now: 2015))                   // reset forgot the pin
    }

    func testEngagedArrivalNeverFolds() {
        var f = NeedsMeFold()
        f.arrive(now: 0, hovering: false, engaged: true)
        XCTAssertFalse(f.isDue(now: 1000))
    }

    func testNotDueBeforeAnyArrival() { XCTAssertFalse(NeedsMeFold().isDue(now: 1000)) }

    func testRemainingTimeTruth() {
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(NeedsMeFold.timeLeft(createdAt: t, timeout: 20, now: t.addingTimeInterval(15)), 5)
        XCTAssertEqual(NeedsMeFold.timeLeft(createdAt: t, timeout: 20, now: t.addingTimeInterval(99)), 0)
        XCTAssertEqual(NeedsMeFold.fractionLeft(createdAt: t, timeout: 20, now: t.addingTimeInterval(15)), 0.25, accuracy: 0.001)
        XCTAssertEqual(NeedsMeFold.fractionLeft(createdAt: t, timeout: 20, now: t.addingTimeInterval(-3)), 1)
    }

    // MARK: model

    private var clockNow: TimeInterval = 0
    private var fds: [[Int32]] = []
    private let t0 = Date()
    override func tearDown() { fds.flatMap { $0 }.filter { $0 >= 0 }.forEach { close($0) }; fds = [] }

    private func model() -> NotchModel {
        clockNow = 1000
        return NotchModel(always: AlwaysStore(url: nil),
                          log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")),
                          clock: { [unowned self] in self.clockNow })
    }
    @discardableResult private func ask(_ m: NotchModel, _ cmd: String = "ls") -> String {
        var p: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &p); fds.append(p)
        let h = HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"\#(cmd)"}}"#.utf8))!
        m.receiveApproval(h, Connection(fd: p[0]), now: t0)
        return m.pending.last!.id
    }
    private func advance(_ m: NotchModel, _ s: TimeInterval) { clockNow += s; m.sweep(now: t0) }

    func testApprovalOpensThenFoldsToBadgeAfterFifteenSeconds() {
        let m = model()
        let id = ask(m)
        XCTAssertEqual(m.density, .expanded); XCTAssertFalse(m.folded)
        advance(m, 14.9); XCTAssertEqual(m.density, .expanded)
        advance(m, 0.2)
        XCTAssertTrue(m.folded); XCTAssertEqual(m.density, .collapsed); XCTAssertFalse(m.resting)
        XCTAssertEqual(m.state, .needsYou)
        XCTAssertEqual(m.badge, "1"); XCTAssertTrue(m.badgeNeedsYou)
        XCTAssertEqual(m.pending.map(\.id), [id])             // still pending, not dropped
        XCTAssertEqual(m.waitingItems.count, 1)
        XCTAssertNil(m.shownPending)                          // keys cannot answer a card nobody sees
    }

    func testFoldedRequestKeepsItsRemainingTime() throws {
        let m = model()
        ask(m)
        advance(m, 16)
        // The model mirrors the hook's 20s; the badge ring drains to createdAt + 20s.
        let d = try XCTUnwrap(m.foldedDeadline)
        XCTAssertEqual(d.end.timeIntervalSince(d.start), 20)
    }

    func testHoverHoldsTheFoldAndLeavingResumes() {
        let m = model()
        ask(m)
        advance(m, 10); m.setHover(true)
        advance(m, 100); XCTAssertFalse(m.folded)
        m.setHover(false); advance(m, 4.9); XCTAssertFalse(m.folded)
        advance(m, 0.2); XCTAssertTrue(m.folded)
    }

    func testArrivingUnderTheCursorStartsPausedAndDoesNotFold() {
        let m = model()
        m.setHover(true)
        ask(m)
        advance(m, 60); XCTAssertFalse(m.folded)
        m.setHover(false); advance(m, 15.1); XCTAssertTrue(m.folded)
    }

    func testNewRequestUnfoldsAndRestarts() {
        let m = model()
        ask(m)
        advance(m, 16); XCTAssertTrue(m.folded)
        ask(m, "pwd")
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded)
        XCTAssertEqual(m.shownPending?.id, m.pending.first?.id)
        advance(m, 14.9); XCTAssertFalse(m.folded)
        advance(m, 0.2); XCTAssertTrue(m.folded)
        XCTAssertEqual(m.badge, "2")
    }

    func testClickOnFoldedNotchOpensAndNeverRefolds() {
        let m = model()
        ask(m)
        advance(m, 16)
        m.toggleOpen()
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded); XCTAssertNotNil(m.shownPending)
        advance(m, 600); XCTAssertFalse(m.folded)
        m.closeDetail(); XCTAssertEqual(m.density, .expanded)   // outside click does not fold an approval either
    }

    func testListJumpPinsTheCardAndNewRequestDoesNotFoldIt() {
        let m = model()
        let id = ask(m)
        advance(m, 16); XCTAssertTrue(m.folded)
        m.openList(); XCTAssertEqual(m.density, .expanded)
        m.activate(.pending(id))
        XCTAssertFalse(m.folded); XCTAssertEqual(m.shownPending?.id, id)
        ask(m, "pwd")
        advance(m, 600)
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded)
    }

    func testRestPanelOpenAtArrivalNeverFolds() {
        let m = model()
        m.toggleOpen(now: t0)
        XCTAssertTrue(m.restOpen)
        ask(m)
        advance(m, 600)
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded)
    }

    func testFoldedRequestStaysAnswerable() {
        let m = model()
        let id = ask(m)
        advance(m, 16)
        m.resolve(id, .allow)
        XCTAssertTrue(m.pending.isEmpty); XCTAssertFalse(m.folded); XCTAssertTrue(m.resting)
        XCTAssertNil(m.badge)
    }

    func testNothingPendingResetsForTheNextRequest() {
        let m = model()
        let id = ask(m)
        m.toggleOpen(); m.resolve(id, .allow)   // not folded, but pinned: resolving must forget the pin
        ask(m, "pwd")
        advance(m, 15.1)
        XCTAssertTrue(m.folded)
    }

    func testFoldedBadgeCountsFinishedChipsToo() {
        let m = model()
        m.apply(HookPayload(json: Data(#"{"session_id":"d","hook_event_name":"Stop","cwd":"/x/q"}"#.utf8))!, now: t0)
        ask(m); advance(m, 16)
        XCTAssertEqual(m.badge, "2"); XCTAssertEqual(m.density, .collapsed)
    }

    func testSoundStillFiresOnceOnArrivalAndNotOnFold() {
        let m = model()
        var n = 0
        m.onSound = { kind, _, _ in if kind == .needsYou { n += 1 } }
        ask(m); advance(m, 16); advance(m, 5)
        XCTAssertEqual(n, 1)
    }

    func testFoldedApprovalStillTimesOutToTheTerminalChip() {
        let m = model()
        let id = ask(m)
        advance(m, 16)
        // The hook gives up at 20s: the peer closes, the sweep drops it and notes the terminal chip as before.
        close(fds[fds.count - 1][1]); fds[fds.count - 1][1] = -1
        m.sweep(now: Date().addingTimeInterval(21)) // t0 is stale by now: every XCTestCase instance is built up front
        XCTAssertFalse(m.pending.contains { $0.id == id })
        XCTAssertEqual(m.terminalItems.count, 1); XCTAssertFalse(m.folded)
    }

    // MARK: review follow-ups

    func testLeavingTheIslandFoldsAtOnceWithoutWaitingForASweep() {
        let m = model()
        ask(m)
        advance(m, 10); m.setHover(true)
        clockNow += 100
        m.setHover(false)                                    // 5s left: not due yet
        XCTAssertFalse(m.folded)
        clockNow += 5.1
        m.setHover(true); m.setHover(false)                  // no sweep ran; a hover change re-evaluates
        XCTAssertTrue(m.folded)
    }

    func testHoverNeverHoldsAHookDeadlineOpen() {
        let m = model()
        let id = ask(m)
        m.setHover(true)
        advance(m, 100); XCTAssertFalse(m.folded)            // held by the cursor
        m.sweep(now: Date().addingTimeInterval(21))          // the hook's 20s wait is over
        XCTAssertFalse(m.pending.contains { $0.id == id })   // dropped by the sweep path, no longer answerable
        XCTAssertEqual(m.terminalItems.count, 1)
    }

    func testTimeoutForRequestMirrorsHookWait() {
        let m = model(); ask(m)
        XCTAssertEqual(m.timeout(for: m.pending[0]), TimeInterval(SettingsInstaller.defaultApprovalTimeout))
    }

    func testOldestRequestDecidesTheFold() {
        let m = model()
        ask(m)
        advance(m, 10)
        ask(m, "pwd")                                        // must not restart the first one's timer
        advance(m, 4.9); XCTAssertFalse(m.folded)
        advance(m, 0.2); XCTAssertTrue(m.folded)             // 15s after the FIRST, not the second
    }

    func testPickingAnAnswerPinsAndClearingItUnpins() {
        let m = model()
        let id = ask(m)
        m.savePartial(id, step: 0, answers: ["Q?": ["x"]])
        advance(m, 600); XCTAssertFalse(m.folded)            // picked: held open
        m.savePartial(id, step: 0, answers: ["Q?": []])      // cleared back to nothing
        advance(m, 14.9); XCTAssertFalse(m.folded)           // a full timer again
        advance(m, 0.2); XCTAssertTrue(m.folded)
    }

    func testClearingAfterOpeningByHandStaysPinned() {
        let m = model()
        let id = ask(m)
        m.openList(); m.activate(.pending(id))
        m.savePartial(id, step: 0, answers: ["Q?": ["x"]])
        m.savePartial(id, step: 0, answers: ["Q?": []])
        advance(m, 600); XCTAssertFalse(m.folded)
    }

    func testReseedAndDisappearSavesNeverPin() {
        let m = model()
        let id = ask(m)
        m.savePartial(id, step: 0, answers: ["Q?": ["x"]], byUser: false)
        advance(m, 15.1)
        XCTAssertTrue(m.folded)                               // the card's own save is not a user action
    }

    func testResolvedJumpTargetDoesNotPinLaterRequests() {
        let m = model()
        let a = ask(m)
        m.openList(); m.activate(.pending(a))
        m.resolve(a, .allow)
        XCTAssertNil(m.focus)
        ask(m, "pwd")
        advance(m, 15.1)
        XCTAssertTrue(m.folded)
    }

    func testClosingTheListClearsAPendingJumpTarget() {
        let m = model()
        let a = ask(m)
        m.activate(.pending(a))
        m.openList(); m.closeList()
        XCTAssertNil(m.focus)
    }
}
