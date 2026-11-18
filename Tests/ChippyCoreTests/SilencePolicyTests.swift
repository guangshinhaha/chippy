import Darwin
import XCTest
@testable import ChippyCore

final class SilencePolicyTests: XCTestCase {
    func testTruthTable() {
        for focus in [false, true] { for locked in [false, true] {
            let s = SilenceState(focus: focus, locked: locked)
            let quiet = focus || locked
            XCTAssertEqual(SilencePolicy.soundsAllowed(s), !quiet)
            XCTAssertEqual(SilencePolicy.mayAutoExpand(s), !quiet)
            XCTAssertEqual(SilencePolicy.mayPeek(s), !quiet)
        } }
    }

    func testFocusParser() {
        func on(_ s: String?) -> Bool { SilencePolicy.focusIsOn(assertionsJSON: s?.data(using: .utf8)) }
        XCTAssertTrue(on(#"{"data":[{"storeAssertionRecords":[{"x":1}]}]}"#))
        XCTAssertFalse(on(#"{"data":[{"storeAssertionRecords":[]}]}"#))
        XCTAssertFalse(on(#"{"data":[{}]}"#))
        XCTAssertFalse(on(#"{"data":[]}"#))
        XCTAssertFalse(on("not json"))
        XCTAssertFalse(on(nil))
    }

    func testSoundPolicySilencedKeepsNeedsYouRules() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        func play(_ k: SoundKind, silenced: Bool, last: Date? = nil, now: Date? = nil) -> Bool {
            SoundPolicy.shouldPlay(kind: k, enabled: true, hostFrontmost: false, locked: false, silenced: silenced,
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
        NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")))
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
        XCTAssertFalse(m.peeking); XCTAssertEqual(m.density, .collapsed); XCTAssertNotNil(m.badge)
        let n = model()
        n.apply(HookPayload(json: Data(#"{"session_id":"d","hook_event_name":"Stop","cwd":"/x/q"}"#.utf8))!)
        XCTAssertTrue(n.peeking)
    }

    func testQuietNeedsYouStillFiresSoundHookForPolicyToDecide() {
        let m = model(); m.silence = { SilenceState(locked: true) }
        var fired = 0; m.onSound = { _, _, _ in fired += 1 }
        ask(m)
        XCTAssertEqual(fired, 1)   // the app's SoundPlayer applies SilencePolicy; the model does not drop the event
    }
}
