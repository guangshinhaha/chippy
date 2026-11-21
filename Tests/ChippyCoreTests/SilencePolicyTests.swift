import Darwin
import XCTest
@testable import ChippyCore

final class SilencePolicyTests: XCTestCase {
    func testTruthTable() {
        for focus in [false, true] { for locked in [false, true] {
            let s = SilenceState(focus: focus, locked: locked)
            let quiet = focus || locked
            XCTAssertEqual(s.isQuiet, quiet)
        } }
    }

    func testFocusParser() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ref = now.timeIntervalSince1970 - SilencePolicy.appleEpochOffset
        func rd(_ s: String?) -> SilencePolicy.FocusReading { SilencePolicy.readFocus(assertionsJSON: s?.data(using: .utf8), now: now) }
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":[{"x":1}]}]}"#), .unknown) // no recognised timestamp: fail open
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":[]}]}"#), .off)
        XCTAssertEqual(rd(#"{"data":[]}"#), .off)
        XCTAssertEqual(rd(#"{"data":[{}]}"#), .unknown)
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":["x"]}]}"#), .unknown)
        XCTAssertEqual(rd("not json"), .unknown)
        XCTAssertEqual(rd(#"{"other":1}"#), .unknown)
        XCTAssertEqual(rd(nil), .unknown)
        // expiry and start are honoured (Apple reference-date seconds)
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":[{"assertionStartDateTimestamp":\#(ref - 100),"assertionExpirationDate":\#(ref - 1)}]}]}"#), .off)
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":[{"assertionStartDateTimestamp":\#(ref - 100),"assertionExpirationDate":\#(ref + 600)}]}]}"#), .on)
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":[{"assertionStartDateTimestamp":\#(ref + 600)}]}]}"#), .off)
        // one expired plus one active record is on
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":[{"assertionExpirationDate":\#(ref - 1)},{"assertionStartDateTimestamp":\#(ref - 5)}]}]}"#), .on)
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":[{"assertionExpirationDate":\#(ref - 1)},{"y":2}]}]}"#), .unknown)
        XCTAssertFalse(SilencePolicy.focusIsOn(assertionsJSON: Data(#"{"data":[{"storeAssertionRecords":[{"mode":"x"}]}]}"#.utf8)))
        XCTAssertFalse(SilencePolicy.focusIsOn(assertionsJSON: nil))
    }

    func testFocusCacheNeverReturnsValueOlderThanTTL() {
        var t = Date(timeIntervalSince1970: 100); var reads = 0; var value = SilencePolicy.FocusReading.on
        var queued: [() -> Void] = []
        let c = FocusCache(ttl: 2, clock: { t }, read: { reads += 1; return value }, async: { queued.append($0) })
        XCTAssertTrue(c.current); XCTAssertEqual(reads, 1)      // first call: synchronous read
        XCTAssertTrue(c.current); XCTAssertEqual(reads, 1)      // fresh: cached
        value = .off
        t = t.addingTimeInterval(1.5)                           // half-aged: cached value, background refresh queued
        XCTAssertTrue(c.current); XCTAssertEqual(queued.count, 1); XCTAssertEqual(reads, 1)
        t = t.addingTimeInterval(1)                             // now past ttl before the refresh ran: sync read wins
        XCTAssertFalse(c.current); XCTAssertEqual(reads, 2)
        queued.removeFirst()()                                  // the late refresh is harmless
        XCTAssertFalse(c.current)
        value = .unknown; t = t.addingTimeInterval(5)
        XCTAssertFalse(c.current); XCTAssertTrue(c.unreadable)
    }

    func testFocusParserIgnoresBooleansAsTimestamps() {
        let ref = Date().timeIntervalSince1970 - SilencePolicy.appleEpochOffset
        func rd(_ j: String) -> SilencePolicy.FocusReading { SilencePolicy.readFocus(assertionsJSON: Data(j.utf8)) }
        // true would read as 1.0 (a 2001 expiry); it is never a timestamp, so the record is unrecognised (unknown, fail open)
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":[{"assertionExpirationDate":true,"assertionStartDateTimestamp":false}]}]}"#), .unknown)
        XCTAssertEqual(rd(#"{"data":[{"storeAssertionRecords":[{"assertionExpirationDate":\#(ref + 600)}]}]}"#), .on)
    }

    func testSessionLockReadIsLiveAndFailsOpen() {
        XCTAssertFalse(SilencePolicy.sessionIsLocked(nil))
        XCTAssertFalse(SilencePolicy.sessionIsLocked([:]))
        XCTAssertFalse(SilencePolicy.sessionIsLocked(["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": false]))
        XCTAssertTrue(SilencePolicy.sessionIsLocked(["CGSSessionScreenIsLocked": true]))
        XCTAssertTrue(SilencePolicy.sessionIsLocked(["kCGSSessionOnConsoleKey": false])) // switched-away user
        // the same dictionary read later says unlocked: no latched state to go stale
        XCTAssertFalse(SilencePolicy.sessionIsLocked(["kCGSSessionOnConsoleKey": true]))
    }

    func testFocusCacheInvalidateForcesFreshRead() {
        let t = Date(timeIntervalSince1970: 100); var reads = 0; var v = SilencePolicy.FocusReading.on
        let c = FocusCache(ttl: 2, clock: { t }, read: { reads += 1; return v }, async: { _ in })
        XCTAssertTrue(c.current); v = .off
        XCTAssertTrue(c.current)          // cached
        c.invalidate()
        XCTAssertFalse(c.current); XCTAssertEqual(reads, 2)
    }

    func testSoundPolicySilencedKeepsNeedsYouRules() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        func play(_ k: SoundKind, silenced: Bool, last: Date? = nil, now: Date? = nil) -> Bool {
            SoundPolicy.shouldPlay(kind: k, enabled: true, hostFrontmost: false, quiet: silenced,
                                   lastPlayed: last, now: now ?? t)
        }
        XCTAssertFalse(play(.needsYou, silenced: true))
        XCTAssertFalse(play(.done, silenced: true))
        XCTAssertTrue(play(.needsYou, silenced: false))
        // needs-you is still never on the 2s cooldown, only the 0.3s dedupe
        XCTAssertTrue(play(.needsYou, silenced: false, last: t, now: t.addingTimeInterval(0.5)))
        XCTAssertFalse(play(.done, silenced: false, last: t, now: t.addingTimeInterval(0.5)))
    }

    private var fds: [[Int32]] = []
    override func tearDown() { fds.flatMap { $0 }.filter { $0 >= 0 }.forEach { close($0) }; fds = [] }

    private func ask(_ m: NotchModel) {
        var p: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &p); fds.append(p)
        let h = HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"PermissionRequest","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"},"chippy_wait":20}"#.utf8))!
        m.receiveApproval(h, Connection(fd: p[0]))
    }
    private func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("chippy-test-\(UUID()).jsonl")))
    }

    func testQuietApprovalArrivesFoldedOnBadgeAndStaysPending() {
        for s in [SilenceState(focus: true), SilenceState(locked: true)] {
            let m = model(); m.silence = { s }
            ask(m)
            XCTAssertEqual(m.pending.count, 1)
            XCTAssertTrue(m.folded); XCTAssertTrue(m.badgeNeedsYou)
            XCTAssertEqual(m.density, .collapsed)
            XCTAssertNotNil(m.foldedDeadline)       // the ring still counts down to the terminal fallback
            m.unfold()                              // a click still opens it
            XCTAssertEqual(m.density, .expanded)
        }
    }

    func testNotQuietApprovalStillAutoExpands() {
        let m = model(); ask(m)
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded)
    }

    func testQuietDoneChipDoesNotPeek() {
        let m = model(); m.silence = { SilenceState(focus: true) }
        m.apply(HookPayload(json: Data(#"{"session_id":"d","hook_event_name":"Stop","cwd":"/x/q"}"#.utf8))!)
        XCTAssertEqual(m.doneItems.count, 1)
        XCTAssertFalse(m.peeking); XCTAssertEqual(m.density, .collapsed); XCTAssertNil(m.badge); XCTAssertTrue(m.badgeDot) // #101: finished-only is a dot
        let n = model()
        n.apply(HookPayload(json: Data(#"{"session_id":"d","hook_event_name":"Stop","cwd":"/x/q"}"#.utf8))!)
        XCTAssertTrue(n.peeking)
    }

    func testQuietNeedsYouStillFiresSoundHookForPolicyToDecide() {
        let m = model(); m.silence = { SilenceState(locked: true) }
        var fired = 0; m.onSound = { _, _, _, _ in fired += 1 }
        ask(m)
        XCTAssertEqual(fired, 1)   // the app's SoundPlayer applies SilencePolicy; the model does not drop the event
    }

    func testQuietApprovalNeverFoldsACardAlreadyOnScreen() {
        let m = model(); ask(m)                    // not quiet: card showing
        XCTAssertEqual(m.density, .expanded)
        m.silence = { SilenceState(focus: true) }
        ask2(m, "t")                               // quiet second request joins the visible card
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded); XCTAssertEqual(m.pending.count, 2)
    }

    func testQuietApprovalNeverFoldsAPinnedCardOrEngagedList() {
        let m = model(); ask(m); m.silence = { SilenceState(locked: true) }
        m.openList()                               // user-opened list is engaged
        ask2(m, "t")
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded)
    }

    func testFocusEndUnfoldsQuietFoldedRequestAndSoundsOnce() {
        var quiet = SilenceState(focus: true)
        let m = model(); m.silence = { quiet }
        var sounds: [Bool] = []; m.onSound = { _, _, _, q in sounds.append(q.isQuiet) }
        ask(m)
        XCTAssertTrue(m.folded); XCTAssertEqual(sounds, [true])   // sound hook got the same quiet value the model used
        m.sweep()
        XCTAssertTrue(m.folded)                                    // still quiet: stays folded
        quiet = SilenceState()
        m.sweep()
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded)
        XCTAssertEqual(sounds, [true, false])                      // one sound when quiet ended
        m.sweep()
        XCTAssertEqual(sounds.count, 2)                            // only once
    }

    func testUserUnfoldedRequestIsNotReSounded() {
        var quiet = SilenceState(focus: true)
        let m = model(); m.silence = { quiet }
        var n = 0; m.onSound = { _, _, _, _ in n += 1 }
        ask(m); m.unfold(); quiet = SilenceState(); m.sweep()
        XCTAssertEqual(n, 1)
    }

    func testQuietFoldedABOpeningOneKeepsTheOther() {
        var quiet = SilenceState(focus: true)
        let m = model(); m.silence = { quiet }
        var sounds: [String] = []; m.onSound = { _, sid, _, q in if !q.isQuiet { sounds.append(sid) } }
        ask(m); ask2(m, "t")
        XCTAssertTrue(m.folded); XCTAssertEqual(m.pending.count, 2)
        m.activate(.pending(m.pending[0].id))           // user opens A by hand
        XCTAssertFalse(m.folded)
        quiet = SilenceState()
        m.sweep()                                   // B was quiet-folded and never sounded: sounds once now
        XCTAssertEqual(sounds, ["t"])
        m.sweep()
        XCTAssertEqual(sounds, ["t"])               // only once
    }

    func testTourDemoRequestIsNeverQuietFoldedAndKeepsEarlierMarks() {
        var quiet = SilenceState(focus: true)
        let m = model(); m.silence = { quiet }
        var sounds: [String] = []; m.onSound = { _, sid, _, q in if !q.isQuiet { sounds.append(sid) } }
        ask(m)                                        // real request, quiet-folded
        XCTAssertTrue(m.folded)
        ask2(m, "demo-a")                             // tour demo during Focus: must show
        XCTAssertFalse(m.folded); XCTAssertEqual(m.density, .expanded)
        quiet = SilenceState(); m.sweep()
        XCTAssertEqual(sounds, ["s"])                 // the earlier real request still sounds once; demo never
        let m2 = model(); m2.silence = { SilenceState(locked: true) }
        ask2(m2, "demo-b")
        XCTAssertFalse(m2.folded); XCTAssertEqual(m2.density, .expanded)
    }

    func testQuietEndKeepsMarksOfOtherRequestsNotRevealed() {
        var quiet = SilenceState(focus: true)
        let m = model(); m.silence = { quiet }
        var sounds: [String] = []; m.onSound = { _, sid, _, q in if !q.isQuiet { sounds.append(sid) } }
        ask(m); ask2(m, "t")
        m.activate(.pending(m.pending[0].id))
        quiet = SilenceState(); m.sweep()
        XCTAssertEqual(sounds, ["t"])
    }

    func testStaleBackgroundRefreshCannotOverwriteNewerValue() {
        var t = Date(timeIntervalSince1970: 100); var v = SilencePolicy.FocusReading.on
        var queued: [() -> Void] = []
        let c = FocusCache(ttl: 2, clock: { t }, read: { v }, async: { queued.append($0) })
        XCTAssertTrue(c.current)
        t = t.addingTimeInterval(1.2); _ = c.current      // half-aged: background refresh queued
        XCTAssertEqual(queued.count, 1)
        v = .off; c.invalidate()
        XCTAssertFalse(c.current)                         // fresh sync read: off
        v = .on; queued[0]()                              // late refresh finishes with a stale generation
        XCTAssertFalse(c.current)                         // not overwritten
    }

    private func ask2(_ m: NotchModel, _ sid: String) {
        var p: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &p); fds.append(p)
        let h = HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"},"chippy_wait":20}"#.utf8))!
        m.receiveApproval(h, Connection(fd: p[0]))
    }
}
