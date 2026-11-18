import XCTest
@testable import ChippyCore

final class PeekTests: XCTestCase {
    // MARK: PeekGate (pure)

    func testPeekExpiryBoundary() {
        var g = PeekGate()
        g.start(now: 100)
        XCTAssertTrue(g.isPeeking(now: 100))
        XCTAssertTrue(g.isPeeking(now: 109.999))
        XCTAssertFalse(g.isPeeking(now: 110))      // exactly 10s: over
        XCTAssertFalse(g.isPeeking(now: 500))
    }

    func testNotPeekingBeforeStart() {
        XCTAssertFalse(PeekGate().isPeeking(now: 0))
    }

    func testHoverPausesAndLeaveRestartsFullCountdown() {
        var g = PeekGate()
        g.start(now: 0)
        g.setHover(true, now: 5)
        XCTAssertTrue(g.isPeeking(now: 1000))      // held open while hovered
        g.setHover(false, now: 1000)
        XCTAssertTrue(g.isPeeking(now: 1009.9))    // full 10s again, not the 5s that were left
        XCTAssertFalse(g.isPeeking(now: 1010))
    }

    func testStartWhileHoveredStaysOpenUntilLeave() {
        var g = PeekGate()
        g.setHover(true, now: 0)
        g.start(now: 1)
        XCTAssertTrue(g.isPeeking(now: 50))
        g.setHover(false, now: 60)
        XCTAssertFalse(g.isPeeking(now: 70))
    }

    func testNewMessageRestartsPeek() {
        var g = PeekGate()
        g.start(now: 0)
        g.start(now: 8)
        XCTAssertTrue(g.isPeeking(now: 17.9))
        XCTAssertFalse(g.isPeeking(now: 18))
    }

    func testBadgeRules() {
        XCTAssertNil(PeekGate.badge(count: 0))
        XCTAssertNil(PeekGate.badge(count: -1))
        XCTAssertEqual(PeekGate.badge(count: 1), "1")
        XCTAssertEqual(PeekGate.badge(count: 9), "9")
        XCTAssertEqual(PeekGate.badge(count: 10), "9+")
        XCTAssertEqual(PeekGate.badge(count: 250), "9+")
    }

    // MARK: NotchModel integration (injected clock)

    private var t: TimeInterval = 0
    private func model() -> NotchModel {
        t = 0
        return NotchModel(always: AlwaysStore(url: nil),
                          log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")),
                          clock: { [unowned self] in self.t })
    }
    private func ev(_ e: String, _ sid: String = "a", extra: String = "") -> HookPayload {
        HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"\#(e)","cwd":"/x/p"\#(extra)}"#.utf8))!
    }

    func testDoneChipPeeksTenSecondsThenCollapsesButStays() {
        let m = model(); let now = Date()
        m.apply(ev("Stop"), now: now)
        XCTAssertEqual(m.density, .compact); XCTAssertTrue(m.visible)
        t = 9.9; m.tick(); XCTAssertEqual(m.density, .compact)
        t = 10; m.tick()
        XCTAssertEqual(m.density, .collapsed); XCTAssertTrue(m.visible)
        XCTAssertEqual(m.doneItems.count, 1)           // still reachable, dismissable
        XCTAssertEqual(m.badge, "1")
        m.toggleOpen(); XCTAssertEqual(m.density, .expanded); XCTAssertTrue(m.doneOpen)
        m.closeDetail(); XCTAssertEqual(m.density, .collapsed)
        m.dismissDone(); XCTAssertNil(m.badge); XCTAssertFalse(m.visible)
    }

    func testHoverHoldsPeekAndLeaveRestarts() {
        let m = model()
        m.apply(ev("Stop"), now: Date())
        t = 4; m.setHover(true)
        t = 60; m.tick(); XCTAssertEqual(m.density, .compact)
        m.setHover(false)
        t = 69.9; m.tick(); XCTAssertEqual(m.density, .compact)
        t = 70; m.tick(); XCTAssertEqual(m.density, .collapsed)
    }

    func testNewMessageRestartsPeekInModel() {
        let m = model(); let now = Date()
        m.apply(ev("Stop", "a"), now: now)
        t = 9; m.apply(ev("Stop", "b"), now: now)
        t = 18; m.tick(); XCTAssertEqual(m.density, .compact)
        t = 19; m.tick(); XCTAssertEqual(m.density, .collapsed)
        XCTAssertEqual(m.badge, "2")
    }

    func testApprovalsNeverAutoCollapse() {
        let m = model()
        let c = Connection.detached()
        m.receiveApproval(ev("PermissionRequest", extra: #","tool_name":"Bash","tool_input":{"command":"ls"}"#), c)
        t = 1000; m.tick(); m.sweep(now: Date())
        XCTAssertEqual(m.density, .expanded)
        XCTAssertEqual(m.pending.count, 1)
    }

    func testApprovalDuringPeekStaysExpandedAndPeekedChipCollapsesAfter() {
        let m = model()
        m.apply(ev("Stop", "a"), now: Date())
        let c = Connection.detached()
        m.receiveApproval(ev("PermissionRequest", "b", extra: #","tool_name":"Bash","tool_input":{"command":"ls"}"#), c)
        t = 30; m.tick(); XCTAssertEqual(m.density, .expanded)
        m.resolve(m.pending[0].id, .deny)
        XCTAssertEqual(m.density, .collapsed)          // the peek ran out meanwhile; the chip waits behind the badge
        XCTAssertEqual(m.badge, "1")
    }

    func testActiveStaysOpenPastPeek() {
        let m = model()
        m.apply(ev("Stop"), now: Date())
        m.toggleOpen()
        t = 100; m.tick(); XCTAssertEqual(m.density, .expanded)
    }

    func testBadgeCapsAtNinePlus() {
        let m = model(); let now = Date()
        for i in 0..<10 { m.apply(ev("Stop", "s\(i)"), now: now) }
        t = 11; m.tick()
        XCTAssertEqual(m.badge, "9+")
    }

}
