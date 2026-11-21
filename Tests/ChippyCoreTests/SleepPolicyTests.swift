import XCTest
@testable import ChippyCore

final class SleepPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAwakeUntilThreshold() {
        let c = IdleClock(now: t0)
        XCTAssertFalse(c.isAsleep(now: t0))
        XCTAssertFalse(c.isAsleep(now: t0.addingTimeInterval(299.9)))
        XCTAssertTrue(c.isAsleep(now: t0.addingTimeInterval(300)))
    }

    func testEventWakesAndRestartsCountdown() {
        var c = IdleClock(now: t0)
        XCTAssertTrue(c.isAsleep(now: t0.addingTimeInterval(400)))
        c.noteEvent(now: t0.addingTimeInterval(400))
        XCTAssertFalse(c.isAsleep(now: t0.addingTimeInterval(400)))
        XCTAssertFalse(c.isAsleep(now: t0.addingTimeInterval(699)))
        XCTAssertTrue(c.isAsleep(now: t0.addingTimeInterval(700)))
    }

    func testCustomThreshold() {
        XCTAssertTrue(IdleClock(now: t0, after: 10).isAsleep(now: t0.addingTimeInterval(10)))
    }

    func testWorkingAndNeedsYouNeverSleep() {
        let c = IdleClock(now: t0)
        let late = t0.addingTimeInterval(9999)
        XCTAssertFalse(SleepPolicy.shouldSleep(state: .working, hasDoneChips: false, clock: c, now: late))
        XCTAssertFalse(SleepPolicy.shouldSleep(state: .needsYou, hasDoneChips: false, clock: c, now: late))
        XCTAssertTrue(SleepPolicy.shouldSleep(state: .idle, hasDoneChips: false, clock: c, now: late))
        XCTAssertFalse(SleepPolicy.shouldSleep(state: .done, hasDoneChips: true, clock: c, now: late)) // a done badge is never hidden
        XCTAssertTrue(SleepPolicy.shouldSleep(state: .done, hasDoneChips: false, clock: c, now: late))
        XCTAssertFalse(SleepPolicy.shouldSleep(state: .idle, hasDoneChips: false, clock: c, now: t0.addingTimeInterval(5)))
    }

    func testModelSleepsAndWakesOnEvent() {
        let log = EventLog(url: scratchURL("chippy-test-\(UUID()).jsonl"))
        let m = NotchModel(always: AlwaysStore(url: nil), log: log)
        let p = HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"Stop","cwd":"/x/r"}"#.utf8))!
        m.apply(p, now: t0)
        m.sweep(now: t0.addingTimeInterval(301))
        XCTAssertEqual(m.state, .done)
        XCTAssertFalse(m.asleep) // finished chip waiting: never sleeps
        m.dismissDone()
        m.sweep(now: t0.addingTimeInterval(302))
        XCTAssertTrue(m.asleep)
        m.apply(p, now: t0.addingTimeInterval(303))
        XCTAssertFalse(m.asleep)
    }

    func testInteractionWakes() {
        let log = EventLog(url: scratchURL("chippy-test-\(UUID()).jsonl"))
        let m = NotchModel(always: AlwaysStore(url: nil), log: log)
        m.wake(now: t0)
        m.sweep(now: t0.addingTimeInterval(301))
        XCTAssertTrue(m.asleep)
        m.setHover(true, now: t0.addingTimeInterval(302))
        XCTAssertTrue(m.asleep) // hover alone never wakes (#85): the sleeping pose must stay visible
        m.toggleOpen(now: t0.addingTimeInterval(302)) // a click does
        XCTAssertFalse(m.asleep)
        m.sweep(now: t0.addingTimeInterval(500))
        XCTAssertFalse(m.asleep)
        m.sweep(now: t0.addingTimeInterval(603))
        XCTAssertTrue(m.asleep)
    }
}

/// #181: the sleeping mascot animates only while someone could see it, and only for a bounded time.
final class SleepAnimationTests: XCTestCase {
    private func go(asleep: Bool = true, reduceMotion: Bool = false, locked: Bool = false, for d: TimeInterval = 60) -> Bool {
        SleepAnimation.shouldAnimate(asleep: asleep, reduceMotion: reduceMotion, screenLocked: locked, asleepFor: d)
    }

    func testAnimatesWhenAsleepVisibleAndRecent() { XCTAssertTrue(go()) }
    func testAwakeNeverAnimates() { XCTAssertFalse(go(asleep: false)) }
    func testReduceMotionIsStatic() { XCTAssertFalse(go(reduceMotion: true)) }
    func testLockedScreenIsStatic() { XCTAssertFalse(go(locked: true)) }

    func testStopsAfterTheLimit() {
        XCTAssertEqual(SleepAnimation.maxAsleep, 600)
        XCTAssertTrue(go(for: 0))
        XCTAssertTrue(go(for: 599.9))
        XCTAssertFalse(go(for: 600))
        XCTAssertFalse(go(for: 3 * 3600))
        XCTAssertTrue(SleepAnimation.shouldAnimate(asleep: true, reduceMotion: false, screenLocked: false, asleepFor: 50, maxAsleep: 60))
        XCTAssertFalse(SleepAnimation.shouldAnimate(asleep: true, reduceMotion: false, screenLocked: false, asleepFor: 60, maxAsleep: 60))
    }

    func testEndIsLimitAfterSleepBegan() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SleepAnimation.end(asleepSince: t0), t0.addingTimeInterval(600))
    }

    /// Offline arithmetic from the policy constants, NOT a measurement of wakeups.
    func testRedrawBudgetIsBounded() {
        XCTAssertEqual(60 / SleepAnimation.frameInterval, 120) // redraws per minute while animating
        XCTAssertEqual(SleepAnimation.maxAsleep / SleepAnimation.frameInterval, 1200) // total per sleep, then 0 until the next wake
    }

    func testModelRecordsWhenSleepBeganAndClearsOnWake() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("chippy-test-\(UUID()).jsonl")))
        m.wake(now: t0)
        XCTAssertNil(m.asleepSince)
        m.sweep(now: t0.addingTimeInterval(301))
        XCTAssertEqual(m.asleepSince, t0.addingTimeInterval(301))
        m.sweep(now: t0.addingTimeInterval(400)) // still asleep: the start does not move
        XCTAssertEqual(m.asleepSince, t0.addingTimeInterval(301))
        m.wake(now: t0.addingTimeInterval(401))
        XCTAssertNil(m.asleepSince)
    }
}
