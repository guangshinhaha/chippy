import XCTest
@testable import ChippyCore

/// #180: the sweep runs every 5s when nothing time-based is on screen, every 0.5s otherwise.
final class SweepCadenceTests: XCTestCase {
    // MARK: pure function

    private func inputs(pending: Bool = false, chips: Bool = false, peeking: Bool = false, folded: Bool = false,
                        quietFolded: Bool = false, panelOpen: Bool = false) -> SweepCadence.Inputs {
        .init(hasPending: pending, hasChips: chips, peeking: peeking, folded: folded, quietFolded: quietFolded, panelOpen: panelOpen)
    }

    func testTheTwoIntervals() {
        XCTAssertEqual(SweepCadence.fast, 0.5)
        XCTAssertEqual(SweepCadence.slow, 5)
    }

    func testNothingOnScreenIsSlow() { XCTAssertEqual(SweepCadence.interval(inputs()), 5) }

    func testPendingIsFast() { XCTAssertEqual(SweepCadence.interval(inputs(pending: true)), 0.5) }
    func testChipsAreFast() { XCTAssertEqual(SweepCadence.interval(inputs(chips: true)), 0.5) }
    func testPeekingIsFast() { XCTAssertEqual(SweepCadence.interval(inputs(peeking: true)), 0.5) }
    func testFoldedIsFast() { XCTAssertEqual(SweepCadence.interval(inputs(folded: true)), 0.5) }
    func testQuietFoldedIsFast() { XCTAssertEqual(SweepCadence.interval(inputs(quietFolded: true)), 0.5) }
    func testOpenPanelIsFast() { XCTAssertEqual(SweepCadence.interval(inputs(panelOpen: true)), 0.5) }

    func testEveryCombinationIsFastUnlessAllAreOff() {
        for bits in 0..<64 {
            let i = inputs(pending: bits & 1 != 0, chips: bits & 2 != 0, peeking: bits & 4 != 0, folded: bits & 8 != 0,
                           quietFolded: bits & 16 != 0, panelOpen: bits & 32 != 0)
            XCTAssertEqual(SweepCadence.interval(i), bits == 0 ? 5 : 0.5, "\(i)")
        }
    }

    func testLabelledFormMatchesTheStruct() {
        XCTAssertEqual(SweepCadence.interval(hasPending: false, hasChips: false, peeking: false, folded: false, quietFolded: false, panelOpen: false), 5)
        XCTAssertEqual(SweepCadence.interval(hasPending: false, hasChips: true, peeking: false, folded: false, quietFolded: false, panelOpen: false), 0.5)
    }

    func testToleranceIsAtLeastTenPercent() {
        for i in [SweepCadence.fast, SweepCadence.slow] { XCTAssertGreaterThanOrEqual(SweepCadence.tolerance(for: i), i * 0.1) }
    }

    // MARK: pacer (when the timer is replaced)

    func testPacerSchedulesFirstThenOnlyWhenTheAnswerChanges() {
        var p = SweepPacer()
        XCTAssertTrue(p.needsSchedule(for: 5)) // nothing scheduled yet
        p.didSchedule(5)
        XCTAssertFalse(p.needsSchedule(for: 5)) // same answer: keep the timer (its deadline is not pushed back)
        XCTAssertTrue(p.needsSchedule(for: 0.5)) // slow to fast: replace it now
        p.didSchedule(0.5)
        XCTAssertFalse(p.needsSchedule(for: 0.5))
        XCTAssertTrue(p.needsSchedule(for: 5)) // fast to slow
    }

    func testPacerNeedsAScheduleAfterTheOneShotFires() {
        var p = SweepPacer()
        p.didSchedule(5); p.didFire()
        XCTAssertTrue(p.needsSchedule(for: 5))
        XCTAssertNil(p.scheduled)
    }

    // MARK: model: every state that needed 0.5s still gets it

    private var clockNow: TimeInterval = 1000
    private var fds: [[Int32]] = []
    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    override func tearDown() { fds.flatMap { $0 }.filter { $0 >= 0 }.forEach { close($0) }; fds = [] }

    private func model(silence: SilenceState = SilenceState()) -> NotchModel {
        clockNow = 1000
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("chippy-test-\(UUID()).jsonl")),
                           clock: { [unowned self] in self.clockNow })
        m.silence = { silence }
        return m
    }

    @discardableResult private func ask(_ m: NotchModel, session: String = "s", wait: Int = 60) -> (id: String, peer: Int32) {
        var p: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &p), 0); fds.append(p)
        let h = HookPayload(json: Data(#"{"session_id":"\#(session)","hook_event_name":"PermissionRequest","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"},"chippy_wait":\#(wait)}"#.utf8))!
        m.receiveApproval(h, Connection(fd: p[0]), now: t0)
        return (m.pending.last!.id, p[1])
    }

    private func stop(_ m: NotchModel, session: String = "d", at now: Date? = nil) {
        m.apply(HookPayload(json: Data(#"{"session_id":"\#(session)","hook_event_name":"Stop","cwd":"/x/q"}"#.utf8))!, now: now ?? t0)
    }

    func testIdleModelIsSlow() {
        let m = model()
        XCTAssertEqual(m.sweepInterval, SweepCadence.slow)
    }

    func testASessionThatIsOnlyWorkingIsSlow() {
        // Working shows no chip, card, peek or countdown: sweep has nothing to do beyond the 5s away poll.
        let m = model()
        m.apply(HookPayload(json: Data(#"{"session_id":"w","hook_event_name":"UserPromptSubmit","cwd":"/x/w"}"#.utf8))!, now: t0)
        XCTAssertEqual(m.state, .working)
        XCTAssertEqual(m.sweepInterval, SweepCadence.slow)
    }

    func testPendingApprovalIsFastAndSlowAgainOnceAnswered() {
        let m = model()
        let a = ask(m)
        XCTAssertEqual(m.sweepInterval, SweepCadence.fast)
        m.resolve(a.id, .allow, now: t0)
        XCTAssertEqual(m.sweepInterval, SweepCadence.slow)
    }

    func testFoldedApprovalIsFast() {
        let m = model()
        ask(m)
        clockNow += 16; m.sweep(now: t0)
        XCTAssertTrue(m.folded)
        XCTAssertEqual(m.sweepInterval, SweepCadence.fast)
    }

    func testQuietFoldedApprovalIsFast() {
        for s in [SilenceState(focus: true), SilenceState(locked: true)] {
            let m = model(silence: s)
            ask(m)
            XCTAssertTrue(m.sweepInputs.quietFolded)
            XCTAssertEqual(m.sweepInterval, SweepCadence.fast)
        }
    }

    func testPeekingFinishedChipIsFastAndStaysFastAsAChipUntilItExpires() {
        let m = model()
        stop(m)
        XCTAssertTrue(m.peeking)
        XCTAssertEqual(m.sweepInterval, SweepCadence.fast)
        clockNow += 11; m.sweep(now: t0.addingTimeInterval(11))
        XCTAssertFalse(m.peeking)
        XCTAssertTrue(m.sweepInputs.hasChips)
        XCTAssertEqual(m.sweepInterval, SweepCadence.fast) // the chip still ages out at doneSeconds
        m.sweep(now: t0.addingTimeInterval(NotchModel.doneSeconds + 1))
        XCTAssertTrue(m.doneItems.isEmpty)
        XCTAssertEqual(m.sweepInterval, SweepCadence.slow)
    }

    func testQuietFinishedChipIsFastWithoutAPeek() {
        let m = model(silence: SilenceState(focus: true))
        stop(m)
        XCTAssertFalse(m.peeking)
        XCTAssertEqual(m.sweepInterval, SweepCadence.fast)
    }

    func testTerminalChipIsFastUntilItExpires() {
        let m = model()
        let req = PendingRequest(payload: HookPayload(json: Data(#"{"session_id":"t","hook_event_name":"PermissionRequest","cwd":"/x/t","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8))!, now: t0)
        m.debugNoteTerminal(req, now: t0)
        XCTAssertEqual(m.terminalItems.count, 1)
        XCTAssertEqual(m.sweepInterval, SweepCadence.fast)
        m.sweep(now: t0.addingTimeInterval(NotchModel.terminalSeconds + 1))
        XCTAssertTrue(m.terminalItems.isEmpty)
        XCTAssertEqual(m.sweepInterval, SweepCadence.slow)
    }

    func testOpenRestPanelIsFastAndClosingItIsSlow() {
        let m = model()
        m.toggleOpen(now: t0)
        XCTAssertTrue(m.restOpen)
        XCTAssertEqual(m.sweepInterval, SweepCadence.fast)
        m.toggleOpen(now: t0)
        XCTAssertEqual(m.sweepInterval, SweepCadence.slow)
    }

    func testOpenWaitingListAndDoneDetailAreFast() {
        let m = model()
        stop(m)
        m.dismissDone(now: t0)
        stop(m, session: "e")
        clockNow += 11; m.sweep(now: t0.addingTimeInterval(11))
        m.openList()
        XCTAssertTrue(m.listOpen)
        XCTAssertTrue(m.sweepInputs.panelOpen)
        m.closeList()
        m.toggleOpen(now: t0) // a chip is showing: its detail
        XCTAssertTrue(m.doneOpen)
        XCTAssertTrue(m.sweepInputs.panelOpen)
    }

    func testAPendingRequestKeepsTheFastCadence() {
        // Sweep's work, and the input that keeps it at 0.5s: hang-up and wait-over (pending), fold (pending, folded), peek expiry (peeking),
        // chip expiry (hasChips), quiet ending (quietFolded, pending), open-panel freshness (panelOpen). Away poll, sleep and Recent prune are
        // 5s-grained already (awayPollInterval, a 5 minute idle clock, a 30 minute TTL), so they need no input.
        let m = model()
        ask(m)
        let i = m.sweepInputs
        XCTAssertTrue(i.hasPending)
        XCTAssertFalse(i.hasChips || i.peeking || i.folded || i.quietFolded || i.panelOpen)
    }

    // MARK: sweeping at 5s still finds a hook that hung up

    func testAHookThatHungUpIsFoundByTheNextFiveSecondTick() {
        let m = model()
        let a = ask(m, wait: 60)
        var now = t0
        for _ in 0..<2 { now = now.addingTimeInterval(5); m.sweep(now: now) } // ticks at +5, +10: the hook is still there
        XCTAssertEqual(m.pending.count, 1)
        close(a.peer); fds[fds.count - 1][1] = -1 // the hook hung up between ticks
        now = now.addingTimeInterval(5); m.sweep(now: now) // the next tick, at most
        XCTAssertTrue(m.pending.isEmpty, "a hang-up must be noticed by the very next 5s tick")
        XCTAssertTrue(m.terminalItems.isEmpty, "gone well before the wait: the terminal was answered, no chip")
    }

    func testAHookThatTimedOutBecomesATerminalChipOnATickAtMostFiveSecondsLate() {
        let m = model()
        ask(m, wait: 12)
        var now = m.pending[0].createdAt // the request is stamped with the real time of arrival
        for _ in 0..<2 { now = now.addingTimeInterval(5); m.sweep(now: now) } // +5, +10: inside the wait
        XCTAssertEqual(m.pending.count, 1)
        now = now.addingTimeInterval(5); m.sweep(now: now) // +15: past the 12s wait
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.terminalItems.count, 1)
    }

    func testAwayPollStillRunsOnEveryFiveSecondTick() {
        let m = model()
        var polls = 0
        m.awaySignal = { polls += 1; return (false, 0) }
        var now = t0
        m.sweep(now: now)
        for _ in 0..<4 { now = now.addingTimeInterval(5); m.sweep(now: now) }
        XCTAssertEqual(polls, 5)
    }

    // MARK: keep-awake timer policy

    func testKeepAwakeTimerRunsOnlyWhileAModeIsOn() {
        XCTAssertFalse(AwakePolicy.needsTimer(effective: .off, clearPending: false))
        XCTAssertTrue(AwakePolicy.needsTimer(effective: .agents, clearPending: false))
        XCTAssertTrue(AwakePolicy.needsTimer(effective: .agentsLid, clearPending: false))
    }

    /// The reviewer's case: mode off, but `pmset disablesleep 0` failed, so the 5s tick is the only retry. It must keep running.
    func testKeepAwakeTimerKeepsRunningWhileAClearIsStillOwed() {
        XCTAssertTrue(AwakePolicy.needsTimer(effective: .off, clearPending: true))
    }

    /// Through the real SleepDisabler: a failed clear leaves `needsClear` true (timer stays), a successful one ends it.
    func testFailedClearKeepsTimerAndSuccessfulClearStopsIt() {
        let marker = scratchURL("disabler-marker")
        var succeed = false
        var finish: ((Bool) -> Void)?
        var clock = t0
        let d = SleepDisabler(marker: marker, now: { clock }, pump: { _ in }) { _, done in finish = done }
        d.set(true); finish?(true)
        XCTAssertTrue(AwakePolicy.needsTimer(effective: .off, clearPending: d.needsClear)) // mode went off, setting still held
        d.set(false); finish?(succeed) // clear fails
        XCTAssertTrue(d.needsClear)
        XCTAssertTrue(AwakePolicy.needsTimer(effective: .off, clearPending: d.needsClear))
        clock = clock.addingTimeInterval(SleepDisabler.retryFloor + 1)
        succeed = true
        d.set(false); finish?(succeed) // the retry the timer exists for
        XCTAssertFalse(d.needsClear)
        XCTAssertFalse(AwakePolicy.needsTimer(effective: .off, clearPending: d.needsClear))
    }

    func testKeepAwakeTimerStopsWhenTheModeExpiresAndAtLaunchWithAnExpiredMode() {
        let until = t0.addingTimeInterval(60)
        func needs(_ mode: AwakeMode, at now: Date, setup: Bool = true) -> Bool {
            AwakePolicy.needsTimer(effective: AwakePolicy.effectiveMode(mode: mode, until: until, now: now, setupInstalled: setup), clearPending: false)
        }
        XCTAssertTrue(needs(.agents, at: t0))
        XCTAssertFalse(needs(.agents, at: until)) // expiry
        XCTAssertFalse(needs(.agentsLid, at: until.addingTimeInterval(1))) // a persisted mode already past its deadline at launch
        XCTAssertTrue(needs(.agentsLid, at: t0, setup: false)) // lid mode without setup runs as agents: still on
    }

    func testOnlyLidClosedModeReadsTheBattery() {
        XCTAssertFalse(AwakePolicy.needsBattery(effective: .off))
        XCTAssertFalse(AwakePolicy.needsBattery(effective: .agents))
        XCTAssertTrue(AwakePolicy.needsBattery(effective: .agentsLid))
    }
}
