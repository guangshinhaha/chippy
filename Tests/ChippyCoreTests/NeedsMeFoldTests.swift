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
    @discardableResult private func ask(_ m: NotchModel, _ cmd: String = "ls", wait: Int? = nil) -> String {
        var p: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &p); fds.append(p)
        let h = HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"\#(cmd)"\#(wait.map { #"},"chippy_wait":\#($0)"# } ?? "}")}"#.utf8))!
        m.receiveApproval(h, Connection(fd: p[0]), now: t0)
        return m.pending.last!.id
    }
    private func advance(_ m: NotchModel, _ s: TimeInterval) { clockNow += s; m.sweep(now: t0) }

    func testBadgeOpensTopRankedItem() {
        let m = model()
        let q = #"{"session_id":"q","hook_event_name":"PermissionRequest","cwd":"/x/q","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","header":"A","multiSelect":false,"options":[{"label":"x","description":""}]}]}}"#
        var p: [Int32] = [0, 0]; socketpair(AF_UNIX, SOCK_STREAM, 0, &p); fds.append(p)
        m.receiveApproval(HookPayload(json: Data(q.utf8))!, Connection(fd: p[0]), now: t0)
        let aid = ask(m)
        advance(m, 16)
        XCTAssertTrue(m.folded)
        m.openBadge()
        XCTAssertFalse(m.listOpen)
        XCTAssertEqual(m.shownPending?.id, aid) // the approval, though the question came first
    }

    func testApprovalWithLongWaitStillBeforeQuestionWithShortWait() {
        let m = model()
        let q = #"{"session_id":"q","hook_event_name":"PermissionRequest","cwd":"/x/q","tool_name":"AskUserQuestion","chippy_wait":5,"tool_input":{"questions":[{"question":"Q?","header":"A","multiSelect":false,"options":[{"label":"x","description":""}]}]}}"#
        var p: [Int32] = [0, 0]; socketpair(AF_UNIX, SOCK_STREAM, 0, &p); fds.append(p)
        m.receiveApproval(HookPayload(json: Data(q.utf8))!, Connection(fd: p[0]), now: t0)
        let aid = ask(m, wait: 100)
        XCTAssertEqual(m.rankedPending.first?.id, aid)
    }

    func testShownCardIsStickyAgainstHigherRankedArrival() {
        let m = model()
        let late = ask(m, wait: 100)   // on screen first
        let soon = ask(m, wait: 10)    // arrives later, ranks first
        XCTAssertEqual(m.shownPending?.id, late) // never swapped under the user's hand
        XCTAssertEqual(m.waitingItems.first?.target, .pending(soon))
        XCTAssertEqual(m.rankedPending.map(\.id), [soon, late])
        m.resolve(late, .allow, now: t0)
        XCTAssertEqual(m.shownPending?.id, soon) // rank picks again once nothing is shown
    }

    func testRankPicksTheCardAfterAnAnswer() {
        let m = model()
        let a = ask(m, wait: 100)
        let b = ask(m, wait: 50)
        let c = ask(m, wait: 10)
        XCTAssertEqual(m.shownPending?.id, a)
        m.resolve(a, .allow, now: t0)
        XCTAssertEqual(m.shownPending?.id, c) // soonest to timeout, not the oldest
        XCTAssertEqual(m.rankedPending.map(\.id), [c, b])
    }

    func testHeaderCountsFromTheRankedList() {
        let m = model()
        let late = ask(m, wait: 100)
        ask(m, wait: 10)
        XCTAssertEqual(m.shownPending?.id, late)
        XCTAssertEqual(m.headerTitle, "Needs you \u{00B7} 2 of 2") // shown card is second in rank
    }

    func testAnsweringAJumpedToCardShowsRankFirstNext() {
        let m = model()
        let a = ask(m, wait: 100)
        let b = ask(m, wait: 50)
        let c = ask(m, wait: 10)
        XCTAssertEqual(m.shownPending?.id, a)
        m.openList(); m.activate(.pending(b))
        XCTAssertEqual(m.shownPending?.id, b)
        XCTAssertEqual(m.headerTitle, "Needs you \u{00B7} 2 of 3") // index is b's rank, not arrival order
        m.resolve(b, .allow, now: t0)
        XCTAssertEqual(m.shownPending?.id, c) // rank-first, not the stale sticky a
        XCTAssertEqual(m.headerTitle, "Needs you \u{00B7} 1 of 2")
    }

    func testFoldTimerStaysWithTheOldestRequest() {
        let m = model()
        ask(m, wait: 100)
        advance(m, 10)
        ask(m, wait: 20) // ranks first, but must not restart or take over the timer
        advance(m, 4); XCTAssertFalse(m.folded)
        advance(m, 2); XCTAssertTrue(m.folded) // the oldest's 15s, counted from its own arrival
    }

    func testFoldedDeadlineIsSoonestKnownEvenWhenTopHasNone() throws {
        let m = model()
        ask(m)            // old relay: no known wait; arrives first
        ask(m, wait: 20)
        advance(m, 16)
        XCTAssertTrue(m.folded)
        let d = try XCTUnwrap(m.foldedDeadline)
        XCTAssertEqual(d.end.timeIntervalSince(d.start), 20)
    }

    func testFoldedDeadlinePicksSoonestAmongKnown() throws {
        let m = model()
        ask(m, wait: 100)
        ask(m, wait: 20)
        advance(m, 16)
        let d = try XCTUnwrap(m.foldedDeadline)
        XCTAssertEqual(d.end.timeIntervalSince(d.start), 20)
    }

    func testBadgeTapPinsOnlyTheOpenedCard() {
        let m = model()
        ask(m); ask(m)
        advance(m, 16)
        XCTAssertTrue(m.folded)
        m.openBadge()
        let shown = try! XCTUnwrap(m.shownPending)
        advance(m, 100); XCTAssertFalse(m.folded) // the opened card is pinned
        m.resolve(shown.id, .allow, now: t0)
        XCTAssertTrue(m.folded) // the other one was never pinned: it folds as soon as the pinned one is answered
    }

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
        ask(m, wait: 20)
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
        m.onSound = { kind, _, _, _ in if kind == .needsYou { n += 1 } }
        ask(m); advance(m, 16); advance(m, 5)
        XCTAssertEqual(n, 1)
    }

    func testFoldedApprovalStillTimesOutToTheTerminalChip() {
        let m = model()
        let id = ask(m)
        advance(m, 16)
        // The hook gives up at the default wait: the peer closes, the sweep drops it and notes the terminal chip as before.
        close(fds[fds.count - 1][1]); fds[fds.count - 1][1] = -1
        m.sweep(now: Date().addingTimeInterval(TimeInterval(SettingsInstaller.defaultApprovalTimeout) + 1)) // t0 is stale by now: every XCTestCase instance is built up front
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
        m.setHover(false)                                    // idempotent leave; no sweep ran, and the re-evaluation folds it
        XCTAssertTrue(m.folded)
    }

    func testHoverNeverHoldsAHookDeadlineOpen() {
        let m = model()
        let id = ask(m, wait: 20)
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

    func testAnyRealInteractionWithTheCardPins() {
        for (step, answers) in [(0, ["Q?": Set(["x"])]), (1, [:]), (0, ["Q?": Set<String>()])] { // a pick, a step change, a clear
            let m = model()
            let id = ask(m)
            m.savePartial(id, step: step, answers: answers)
            advance(m, 600)
            XCTAssertFalse(m.folded, "step \(step) answers \(answers)")
        }
    }

    func testUnknownWaitIsNeverDroppedOnTimeoutAndShowsNoRing() {
        let m = model()
        let id = ask(m)                                       // older relay: no chippy_wait
        XCTAssertNil(m.knownTimeout(for: m.pending[0]))
        advance(m, 16)
        XCTAssertNil(m.foldedDeadline)
        m.sweep(now: Date().addingTimeInterval(500))
        XCTAssertTrue(m.pending.contains { $0.id == id })     // only a hang-up ends it
        close(fds[fds.count - 1][1]); fds[fds.count - 1][1] = -1
        m.sweep(now: Date().addingTimeInterval(500))
        XCTAssertFalse(m.pending.contains { $0.id == id })
    }

    func testHookWaitRejectsBooleansAndOutOfRangeForTheTool() {
        func w(_ x: String, tool: String = "Bash") -> TimeInterval? {
            HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"\#(tool)","chippy_wait":\#(x)}"#.utf8))!.waitSeconds
        }
        XCTAssertNil(w("true")); XCTAssertNil(w("false"))
        XCTAssertEqual(w("120"), 120); XCTAssertNil(w("121"))
        XCTAssertEqual(w("300", tool: "AskUserQuestion"), 300); XCTAssertNil(w("301", tool: "AskUserQuestion"))
    }

    func testApprovalReplacingAnOpenDoneCardIsNotUserOpened() {
        let m = model()
        m.apply(HookPayload(json: Data(#"{"session_id":"d","hook_event_name":"Stop","cwd":"/x/q"}"#.utf8))!, now: t0)
        m.toggleOpen()                                        // done detail open by click
        XCTAssertTrue(m.doneOpen)
        ask(m)
        XCTAssertFalse(m.doneOpen)
        advance(m, 15.1)
        XCTAssertTrue(m.folded); XCTAssertEqual(m.density, .collapsed)
    }

    func testPointerArrivingAfterTheDeadlineButBeforeTheFoldHoldsIt() {
        var f = NeedsMeFold()
        f.arrive(now: 0, hovering: false, engaged: false)
        f.setHover(true, now: 20)                             // due since 15, not yet applied
        XCTAssertFalse(f.isDue(now: 500))
        f.setHover(false, now: 500)
        XCTAssertFalse(f.isDue(now: 514.9)); XCTAssertTrue(f.isDue(now: 515))

        let m = model()
        ask(m)
        clockNow += 16                                        // due, but no sweep or refresh has folded it yet
        m.setHover(true)
        XCTAssertFalse(m.folded)                              // never folded under the pointer
        advance(m, 100); XCTAssertFalse(m.folded)
        m.setHover(false); advance(m, 15.1); XCTAssertTrue(m.folded)
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

    func testClosingTheListKeepsTheCardTheUserChose() {
        let m = model()
        let a = ask(m); ask(m, "pwd")
        m.activate(.pending(a))
        m.openList(); m.closeList()
        XCTAssertEqual(m.shownPending?.id, a)                // the card does not switch
    }

    func testCustomHookWaitDrivesTimeoutRingAndSweep() {
        let m = model()
        let id = ask(m, wait: 60)
        XCTAssertEqual(m.timeout(for: m.pending[0]), 60)
        advance(m, 16)
        XCTAssertEqual(m.foldedDeadline.map { $0.end.timeIntervalSince($0.start) }, 60)   // the ring drains over 60s, not 20
        m.sweep(now: Date().addingTimeInterval(30))
        XCTAssertTrue(m.pending.contains { $0.id == id })    // a live 60s request is not dropped at the default 20s
        m.sweep(now: Date().addingTimeInterval(61))
        XCTAssertFalse(m.pending.contains { $0.id == id })
    }

    func testHookWaitFieldIsValidated() {
        func w(_ x: String) -> TimeInterval? {
            HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","chippy_wait":\#(x)}"#.utf8))!.waitSeconds
        }
        XCTAssertEqual(w("45"), 45)
        XCTAssertNil(w("0")); XCTAssertNil(w("-5")); XCTAssertNil(w("99999")); XCTAssertNil(w("\"x\""))
        XCTAssertNil(HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PermissionRequest"}"#.utf8))!.waitSeconds)
    }

    func testOpeningTheListPausesFoldingAndCloseRestartsTheTimer() {
        let m = model()
        ask(m)
        advance(m, 5)
        m.openList(); XCTAssertFalse(m.folded)
        advance(m, 600); XCTAssertFalse(m.folded)            // no fold while the list is open
        m.closeList()
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded)
        advance(m, 14.9); XCTAssertFalse(m.folded)           // a fresh full timer, not a pin
        advance(m, 0.2); XCTAssertTrue(m.folded)
    }

    func testListRoundTripKeepsAPinnedCardPinned() {
        let m = model()
        ask(m)
        m.savePartial(m.pending[0].id, step: 0, answers: [:])  // a real interaction pins
        m.openList(); m.closeList()
        advance(m, 600); XCTAssertFalse(m.folded)
    }

    func testListOpenedFromTheBadgeReturnsToTheBadge() {
        let m = model()
        ask(m)
        advance(m, 16); XCTAssertTrue(m.folded)
        m.openList(); m.closeList()
        XCTAssertTrue(m.folded); XCTAssertEqual(m.density, .collapsed)
    }

    func testPinnedLaterRequestFoldsAwayOnceAnsweredBecauseTheOlderIsDue() {
        let m = model()
        ask(m)                                               // A
        advance(m, 10)
        let b = ask(m, "pwd")                                // B
        m.activate(.pending(b))                              // user opens B by hand
        advance(m, 100); XCTAssertFalse(m.folded)            // pinned B holds the panel
        m.resolve(b, .allow)
        XCTAssertTrue(m.folded)                              // A was due long ago: nothing keeps it open
    }
}
