import Darwin
import XCTest
@testable import ChippyCore

final class EventLogTests: XCTestCase {
    func req(_ cmd: String = "npm install", at t: Date) -> PendingRequest {
        let p = HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s", "cwd": "/w/api", "hook_event_name": "PermissionRequest",
            "tool_name": "Bash", "tool_input": ["command": cmd]]))!
        return PendingRequest(payload: p, now: t)
    }

    func tmp() -> URL { scratchURL("ev-\(UUID()).jsonl") }

    func testLineHasTimestampWaitAndChannelButNoCommandText() throws {
        let url = tmp(); let log = EventLog(url: url)
        let t0 = Date(timeIntervalSince1970: 1_000)
        log.append(req("echo SECRET-TOKEN", at: t0), channel: .notch, decision: "allow", now: t0.addingTimeInterval(4.25))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("SECRET-TOKEN"))
        let e = try XCTUnwrap(EventLog.read(url).first)
        XCTAssertEqual(e.waitMs, 4250); XCTAssertEqual(e.channel, .notch); XCTAssertEqual(e.decision, "allow")
        XCTAssertEqual(e.project, "api"); XCTAssertFalse(e.ts.isEmpty)
    }

    func testAppendOnlyAndSurvivesRestart() {
        let url = tmp(); let t = Date()
        EventLog(url: url).append(req(at: t), channel: .notch, decision: "allow", now: t)
        EventLog(url: url).append(req(at: t), channel: .terminal, decision: "none", now: t) // "restart"
        XCTAssertEqual(EventLog.read(url).count, 2)
    }

    func testModelLogsEveryHandledApprovalWithItsChannel() {
        let url = tmp()
        let m = NotchModel(always: AlwaysStore(url: tmp()), log: EventLog(url: url))
        func pair() -> (Connection, Int32) {
            var fds: [Int32] = [0, 0]; socketpair(AF_UNIX, SOCK_STREAM, 0, &fds); return (Connection(fd: fds[0]), fds[1])
        }
        func payload(_ c: String) -> HookPayload {
            HookPayload(json: try! JSONSerialization.data(withJSONObject: [
                "session_id": "s", "cwd": "/w/api", "hook_event_name": "PermissionRequest",
                "tool_name": "Bash", "tool_input": ["command": c]]))!
        }
        let (c1, _) = pair(), (c2, f2) = pair(), (c3, _) = pair(), (c4, _) = pair()
        m.receiveApproval(payload("a"), c1); m.resolve(m.pending[0].id, .allow)            // notch click
        m.receiveApproval(payload("b"), c2); close(f2); m.sweep()                            // terminal / timeout
        m.receiveApproval(payload("c"), c3); m.resolve(m.pending[0].id, .always)            // always
        m.receiveApproval(payload("c"), c4)                                                  // auto by always
        let ev = EventLog.read(url)
        XCTAssertEqual(ev.map(\.channel), [.notch, .terminal, .notch, .notch])
        XCTAssertEqual(ev.map(\.decision), ["allow", "none", "always", "auto_always"])
    }

    func testBothPRDMeasuresComputeFromTheLog() {
        let mk = { (ms: Int, c: Channel) in WaitEvent(ts: "t", waitMs: ms, channel: c, decision: "x", project: "p", tool: "Bash") }
        let s = WaitSummary([mk(1000, .notch), mk(3000, .notch), mk(20000, .terminal), mk(2000, .notch)])
        XCTAssertEqual(s.totalWaitMs, 26000)          // idle-wait baseline
        XCTAssertEqual(s.notchShare, 0.75)            // share actioned from notch vs terminal
        XCTAssertEqual(s.medianWaitMs, 2500)          // even count averages the middle two
    }

    func ev(_ ts: Date, _ ms: Int, _ c: Channel) -> WaitEvent {
        WaitEvent(ts: ISO8601DateFormatter().string(from: ts), waitMs: ms, channel: c, decision: "x", project: "p", tool: "Bash")
    }

    func testSinceIncludesMidnightAndDropsJustBefore() {
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let s = WaitSummary([ev(midnight.addingTimeInterval(-1), 1000, .notch), ev(midnight, 2000, .notch),
                             ev(midnight.addingTimeInterval(60), 3000, .terminal)], since: midnight)
        XCTAssertEqual(s.total, 2); XCTAssertEqual(s.totalWaitMs, 5000)
        let bad = WaitEvent(ts: "garbage", waitMs: 1, channel: .notch, decision: "x", project: "p", tool: "t")
        XCTAssertEqual(WaitSummary([bad], since: .distantPast).total, 0)
    }

    func testMenuLineFormatting() {
        func line(_ ms: Int, asks: Bool = false) -> String {
            WaitSummary([ev(Date(), ms, .notch), ev(Date(), 0, .terminal)]).menuLine(label: "L", showAsks: asks)
        }
        XCTAssertEqual(line(45_000), "L: 45s · 50% from notch")
        XCTAssertEqual(line(200_000), "L: 3m 20s · 50% from notch")
        XCTAssertEqual(line(41 * 60_000, asks: true), "L: 41m · 50% from notch (2 asks)")
        XCTAssertEqual(line(3_900_000), "L: 1h 5m · 50% from notch")
        XCTAssertEqual(WaitSummary([]).menuLine(label: "L"), "L: none yet")
    }

    func testDemoRequestsAreNotLogged() {
        let url = tmp()
        let m = NotchModel(always: AlwaysStore(url: tmp()), log: EventLog(url: url))
        func pair() -> (Connection, Int32) {
            var fds: [Int32] = [0, 0]; socketpair(AF_UNIX, SOCK_STREAM, 0, &fds); return (Connection(fd: fds[0]), fds[1])
        }
        func payload(_ sid: String) -> HookPayload {
            HookPayload(json: try! JSONSerialization.data(withJSONObject: [
                "session_id": sid, "cwd": "/w/api", "hook_event_name": "PermissionRequest",
                "tool_name": "Bash", "tool_input": ["command": "x"]]))!
        }
        let (c1, _) = pair(), (c2, _) = pair()
        m.receiveApproval(payload("demo-a"), c1); m.resolve(m.pending[0].id, .allow)
        XCTAssertTrue(EventLog.read(url).isEmpty)
        m.receiveApproval(payload("real"), c2); m.resolve(m.pending[0].id, .allow)
        XCTAssertEqual(EventLog.read(url).count, 1)
    }
}
