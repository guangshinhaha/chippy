import Darwin
import XCTest
@testable import ChippyCore

final class RestingTests: XCTestCase {
    let t0 = Date()

    private func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: nil),
                   log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")))
    }
    private func ev(_ e: String, _ sid: String = "a", cwd: String = "/x/p") -> HookPayload {
        HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"\#(e)","cwd":"\#(cwd)","chippy_branch":"main"}"#.utf8))!
    }
    /// Finish a thread and dismiss its chip.
    private func finish(_ m: NotchModel, _ sid: String, cwd: String = "/x/p", at: Date) {
        m.apply(ev("Stop", sid, cwd: cwd), now: at)
        m.dismissDone(sid, now: at)
    }

    // MARK: resting state

    func testFreshModelRestsAndIsNeverHidden() {
        let m = model()
        XCTAssertTrue(m.resting); XCTAssertEqual(m.density, .collapsed)
    }

    func testRestsAfterEverythingIsDismissed() {
        let m = model()
        m.apply(ev("Stop"), now: t0)
        XCTAssertFalse(m.resting)
        m.dismissDone()
        XCTAssertTrue(m.resting); XCTAssertEqual(m.density, .collapsed)
    }

    func testRestsWhileSessionsJustRun() {
        let m = model()
        m.apply(ev("UserPromptSubmit"), now: t0)
        XCTAssertTrue(m.resting)
    }

    func testClickOpensRestPanelAndItStaysOpen() {
        let m = model()
        m.toggleOpen(now: t0)
        XCTAssertTrue(m.restOpen); XCTAssertEqual(m.density, .expanded); XCTAssertFalse(m.resting)
        m.sweep(now: t0.addingTimeInterval(5)) // no timer closes it
        XCTAssertTrue(m.restOpen); XCTAssertEqual(m.density, .expanded)
        m.toggleOpen(now: t0.addingTimeInterval(6)) // another click closes it
        XCTAssertFalse(m.restOpen); XCTAssertTrue(m.resting)
    }

    func testClickAtRestOpensRecentEvenWithLingeringSessionRows() {
        let m = model()
        finish(m, "a", cwd: "/x/api", at: t0) // the session row lingers after its chip is dismissed
        XCTAssertFalse(m.sessions.isEmpty); XCTAssertTrue(m.resting)
        m.toggleOpen(now: t0)
        XCTAssertTrue(m.restOpen); XCTAssertEqual(m.recent.items.map(\.project), ["api"])
    }

    func testPassiveChipDoesNotCollapseTheOpenRestPanel() {
        let m = model()
        m.toggleOpen(now: t0)
        m.apply(ev("Stop", "a", cwd: "/x/api"), now: t0) // a finished chip arrives under the user
        XCTAssertTrue(m.restOpen); XCTAssertEqual(m.density, .expanded)
        XCTAssertEqual(m.doneItems.count, 1)
        m.dismissDone(now: t0)
        XCTAssertTrue(m.restOpen) // still open until the user closes it
        m.toggleOpen(now: t0)
        XCTAssertFalse(m.restOpen); XCTAssertTrue(m.resting)
    }

    func testTerminalChipDoesNotCollapseTheOpenRestPanel() {
        let m = model()
        m.toggleOpen(now: t0)
        let q = HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","cwd":"/x/p","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#.utf8))!
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        m.receiveApproval(q, Connection(fd: fds[0]), now: t0) // unsupported question falls back to the terminal chip
        XCTAssertEqual(m.terminalItems.count, 1)
        XCTAssertTrue(m.restOpen); XCTAssertEqual(m.density, .expanded)
        close(fds[1])
    }

    func testClickWithAChipShowingOpensItsDetailNotTheRestPanel() {
        let m = model()
        m.apply(ev("Stop"), now: t0)
        m.toggleOpen(now: t0)
        XCTAssertTrue(m.doneOpen); XCTAssertFalse(m.restOpen)
    }

    func testOutsideClickClosesRestPanel() {
        let m = model()
        m.toggleOpen(now: t0)
        m.closeDetail()
        XCTAssertFalse(m.restOpen); XCTAssertTrue(m.resting)
    }

    func testApprovalTakesOverTheRestPanel() {
        let m = model()
        m.toggleOpen(now: t0)
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        let p = HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8))!
        m.receiveApproval(p, Connection(fd: fds[0]), now: t0)
        XCTAssertFalse(m.restOpen); XCTAssertEqual(m.state, .needsYou)
        close(fds[1])
    }

    func testHoverDoesNotWakeButClickDoes() {
        let m = model()
        m.sweep(now: Date().addingTimeInterval(400))
        XCTAssertTrue(m.asleep)
        m.setHover(true); m.setHover(false)
        XCTAssertTrue(m.asleep)
        m.toggleOpen()
        XCTAssertFalse(m.asleep)
    }

    func testSleepsAtRestAfterFiveMinutes() {
        let m = model()
        m.sweep(now: Date().addingTimeInterval(299))
        XCTAssertFalse(m.asleep)
        m.sweep(now: Date().addingTimeInterval(301))
        XCTAssertTrue(m.asleep); XCTAssertTrue(m.resting)
    }

    // MARK: Recent

    func testDismissedChipLandsInRecentNewestFirst() {
        let m = model()
        finish(m, "a", cwd: "/x/api", at: t0)
        finish(m, "b", cwd: "/x/web", at: t0.addingTimeInterval(10))
        XCTAssertEqual(m.recent.items.map(\.project), ["web", "api"])
    }

    func testExpiredChipLandsInRecent() {
        let m = model()
        m.apply(ev("Stop", "a", cwd: "/x/api"), now: t0)
        m.sweep(now: t0.addingTimeInterval(NotchModel.doneSeconds + 1))
        XCTAssertTrue(m.doneItems.isEmpty)
        XCTAssertEqual(m.recent.items.map(\.project), ["api"])
    }

    func testChipLeavingByResumeLandsInRecent() {
        let m = model()
        m.apply(ev("Stop", "a", cwd: "/x/api"), now: t0)
        m.apply(ev("UserPromptSubmit", "a", cwd: "/x/api"), now: t0.addingTimeInterval(30))
        XCTAssertTrue(m.doneItems.isEmpty)
        XCTAssertEqual(m.recent.items.map(\.project), ["api"])
    }

    func testChipLeavingBySessionEndLandsInRecent() {
        let m = model()
        m.apply(ev("Stop", "a", cwd: "/x/api"), now: t0)
        m.apply(ev("SessionEnd", "a", cwd: "/x/api"), now: t0.addingTimeInterval(30))
        XCTAssertEqual(m.recent.items.map(\.project), ["api"])
    }

    func testRecentUsesTheCallersClockNotTheWallClock() {
        let m = model()
        let past = Date(timeIntervalSince1970: 1_000_000) // long before the wall clock, but within the TTL of `now`
        m.apply(ev("Stop", "a", cwd: "/x/api"), now: past)
        m.dismissDone("a", now: past.addingTimeInterval(60))
        XCTAssertEqual(m.recent.items.count, 1)
    }

    func testRecentIsCappedAtFive() {
        var r = RecentList()
        for i in 0..<8 { r.add(RecentItem(sessionId: "s\(i)", project: "p\(i)", at: t0.addingTimeInterval(Double(i))), now: t0.addingTimeInterval(8)) }
        XCTAssertEqual(r.items.count, RecentList.cap)
        XCTAssertEqual(r.items.map(\.project), ["p7", "p6", "p5", "p4", "p3"])
    }

    func testRecentKeepsOneEntryPerSession() {
        var r = RecentList()
        r.add(RecentItem(sessionId: "s", project: "old", at: t0), now: t0)
        r.add(RecentItem(sessionId: "s", project: "new", at: t0.addingTimeInterval(5)), now: t0.addingTimeInterval(5))
        XCTAssertEqual(r.items.map(\.project), ["new"])
    }

    func testRecentDropsAfterTTL() {
        var r = RecentList()
        r.add(RecentItem(sessionId: "s", project: "p", at: t0), now: t0)
        XCTAssertFalse(r.prune(now: t0.addingTimeInterval(RecentList.ttl)))
        XCTAssertTrue(r.prune(now: t0.addingTimeInterval(RecentList.ttl + 1)))
        XCTAssertTrue(r.items.isEmpty)
    }

    func testModelSweepPrunesRecent() {
        let m = model()
        finish(m, "a", at: Date())
        XCTAssertEqual(m.recent.items.count, 1)
        m.sweep(now: Date().addingTimeInterval(RecentList.ttl + 5))
        XCTAssertTrue(m.recent.items.isEmpty)
    }

    func testDemoSessionsNeverEnterRecent() {
        let m = model()
        finish(m, "demo-1", at: t0)
        XCTAssertTrue(m.recent.items.isEmpty)
    }

    /// PDPA: an entry carries only repo, time and host. A reply, prompt or command can't reach it.
    func testRecentCarriesNoReplyOrPromptText() {
        let m = model()
        let stop = HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"Stop","cwd":"/x/api","last_assistant_message":"SECRET-REPLY"}"#.utf8))!
        m.apply(ev("UserPromptSubmit", "a", cwd: "/x/api"), now: t0)
        m.apply(stop, now: t0)
        m.dismissDone("a")
        let dump = String(describing: m.recent.items)
        XCTAssertFalse(dump.contains("SECRET-REPLY"))
        let labels = Mirror(reflecting: m.recent.items[0]).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["sessionId", "project", "at", "host", "cwd"]) // cwd only resolves the repo label, never shown
    }

    // MARK: metrics

    func testRestingIsAlwaysATabNeverWings() {
        let m = NotchMetrics.sample14
        XCTAssertEqual(m.size(for: .collapsed, resting: true).width, m.width)
        XCTAssertGreaterThan(m.size(for: .collapsed, resting: true).height, m.band)
        XCTAssertNotEqual(m.size(for: .collapsed, resting: true), m.size(for: .collapsed, resting: false))
        XCTAssertEqual(m.size(for: .expanded, resting: true), m.size(for: .expanded)) // only collapsed rests
    }

    func testRestingOnScreenWithoutNotchIsASmallClickablePill() {
        let m = NotchMetrics.none
        let s = m.size(for: .collapsed, resting: true)
        XCTAssertEqual(s.width, NotchMetrics.flatRestingWidth)
        XCTAssertGreaterThanOrEqual(s.height, NotchMetrics.glanceIcon)
        XCTAssertLessThan(s.width, m.size(for: .collapsed).width)
    }

    func testRestingFitsInsideTheFixedHostWindow() {
        for m in [NotchMetrics.sample14, NotchMetrics(width: 200, height: 38), .none] {
            let box = m.maxSize, s = m.restingSize
            XCTAssertLessThanOrEqual(s.width, box.width); XCTAssertLessThanOrEqual(s.height, box.height)
        }
    }
}
