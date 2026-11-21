import Combine
import XCTest
@testable import ChippyCore

/// #121: refresh() runs on every hook event. A @Published write with an equal value still notifies, and KeepAwake
/// re-reads the battery, the filesystem and its menu on every `$state` emission, so a tool event that changes none of
/// state / tall / density / chips must not emit on them (that stalled the main thread for tens of ms with several sessions).
final class RefreshChurnTests: XCTestCase {
    private func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("churn-\(UUID()).jsonl")))
    }
    private func ev(_ e: String, _ sid: String, _ extra: String = "") -> HookPayload {
        HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"\#(e)","cwd":"/x/\#(sid)"\#(extra)}"#.utf8))!
    }

    func testToolEventsFromEightSessionsDoNotReEmitUnchangedState() {
        let m = model(); let t = Date()
        for i in 0..<8 { m.apply(ev("UserPromptSubmit", "s\(i)"), now: t) }
        m.apply(ev("Stop", "s0", #","last_assistant_message":"Done.""#), now: t)
        m.toggleOpen(now: t)

        var seen: [String: Int] = [:]
        var bag = Set<AnyCancellable>()
        m.$state.dropFirst().sink { _ in seen["state", default: 0] += 1 }.store(in: &bag)
        m.$tall.dropFirst().sink { _ in seen["tall", default: 0] += 1 }.store(in: &bag)
        m.$density.dropFirst().sink { _ in seen["density", default: 0] += 1 }.store(in: &bag)
        m.$doneItems.dropFirst().sink { _ in seen["done", default: 0] += 1 }.store(in: &bag)
        m.$terminalItems.dropFirst().sink { _ in seen["terminal", default: 0] += 1 }.store(in: &bag)

        for k in 0..<40 {
            m.apply(ev(k % 2 == 0 ? "PreToolUse" : "PostToolUse", "s\(1 + k % 7)", #","tool_name":"Read","tool_input":{"file_path":"/x/f.swift"}"#), now: t.addingTimeInterval(Double(k)))
        }
        XCTAssertEqual(seen, [:], "an unchanged state/tall/density/chip list must not publish")
    }

    func testChangesStillPublish() {
        let m = model(); let t = Date()
        var states: [ChippyState] = []
        let c = m.$state.dropFirst().sink { states.append($0) }
        m.apply(ev("UserPromptSubmit", "a"), now: t)
        m.apply(ev("Stop", "a"), now: t)
        XCTAssertEqual(states, [.working, .done])
        c.cancel()
    }

    /// The 1s tick (sweep) and repeated no-change events must not republish sessions, chips or state.
    func testTickAndExpirySweepWithNoChangeDoNotPublish() {
        let m = model(); let t = Date()
        for i in 0..<4 { m.apply(ev("UserPromptSubmit", "s\(i)"), now: t) }
        m.apply(ev("Stop", "s0", #","last_assistant_message":"Done.""#), now: t)

        var seen: [String: Int] = [:]
        var bag = Set<AnyCancellable>()
        m.$sessions.dropFirst().sink { _ in seen["sessions", default: 0] += 1 }.store(in: &bag)
        m.$doneItems.dropFirst().sink { _ in seen["done", default: 0] += 1 }.store(in: &bag)
        m.$terminalItems.dropFirst().sink { _ in seen["terminal", default: 0] += 1 }.store(in: &bag)
        m.$state.dropFirst().sink { _ in seen["state", default: 0] += 1 }.store(in: &bag)
        m.$density.dropFirst().sink { _ in seen["density", default: 0] += 1 }.store(in: &bag)
        m.$peeking.dropFirst().sink { _ in seen["peeking", default: 0] += 1 }.store(in: &bag)

        for k in 1...20 { m.sweep(now: t.addingTimeInterval(Double(k) * 0.1)) }
        m.dismissTerminal()                       // nothing to clear
        m.dismissDone("nope")                     // no such chip
        XCTAssertEqual(seen, [:], "an idle tick must not publish sessions, chips, state, density or peeking")
    }

    func testExpiryStillPublishesOnce() {
        let m = model(); let t = Date()
        m.apply(ev("UserPromptSubmit", "a"), now: t)
        m.apply(ev("Stop", "a", #","last_assistant_message":"Done.""#), now: t)
        var n = 0
        let c = m.$doneItems.dropFirst().sink { _ in n += 1 }
        m.sweep(now: t.addingTimeInterval(NotchModel.doneSeconds + 1))
        XCTAssertEqual(n, 1); XCTAssertTrue(m.doneItems.isEmpty)
        c.cancel()
    }
}
