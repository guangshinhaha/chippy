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
        let log = EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl"))
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
        let log = EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl"))
        let m = NotchModel(always: AlwaysStore(url: nil), log: log)
        m.wake(now: t0)
        m.sweep(now: t0.addingTimeInterval(301))
        XCTAssertTrue(m.asleep)
        m.setHover(true, now: t0.addingTimeInterval(302))
        XCTAssertFalse(m.asleep)
        m.sweep(now: t0.addingTimeInterval(500))
        XCTAssertFalse(m.asleep)
        m.sweep(now: t0.addingTimeInterval(603))
        XCTAssertTrue(m.asleep)
    }
}
