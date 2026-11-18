import XCTest
@testable import ChippyCore

private func payload(_ o: [String: Any]) -> HookPayload {
    HookPayload(json: try! JSONSerialization.data(withJSONObject: o))!
}

final class ProcessTreeTests: XCTestCase {
    // 10 (relay) -> 9 (claude, tty) -> 8 (zsh, tty) -> 7 (app) -> 1
    let table: [Int32: Int32] = [10: 9, 9: 8, 8: 7, 7: 1]
    func walk(apps: Set<Int32> = [7], parents: [Int32: Int32]? = nil, max: Int = 32) -> (hostPid: Int32?, tty: String?) {
        let t = parents ?? table
        return ProcessTree.walk(start: 10, parent: { t[$0] }, isApp: { apps.contains($0) },
                                tty: { $0 == 8 || $0 == 9 ? "ttys0\($0)" : nil }, maxSteps: max)
    }

    func testStopsAtFirstAppAndTakesNearestTTY() {
        let r = walk(apps: [7, 1000])
        XCTAssertEqual(r.hostPid, 7); XCTAssertEqual(r.tty, "ttys09")
    }
    func testNoAppMeansNoHost() { XCTAssertNil(walk(apps: []).hostPid) }  // e.g. tmux: parent is launchd
    func testDepthCap() { XCTAssertNil(walk(max: 3).hostPid); XCTAssertEqual(walk(max: 4).hostPid, 7) }
    func testCycleTerminates() { XCTAssertNil(walk(apps: [], parents: [10: 9, 9: 10]).hostPid) }
    func testFirstAppWinsOverOuter() { XCTAssertEqual(walk(apps: [7, 8]).hostPid, 8) }
}

final class HostCarryTests: XCTestCase {
    func ev(_ name: String, host: Bool) -> HookPayload {
        var o: [String: Any] = ["session_id": "s", "cwd": "/w/p", "hook_event_name": name, "chippy_branch": "b"]
        if host { o["chippy_host_pid"] = 4242; o["chippy_host_bundle"] = "com.apple.Terminal"; o["chippy_tty"] = "ttys004" }
        return payload(o)
    }
    let want = HostInfo(pid: 4242, bundle: "com.apple.Terminal", tty: "ttys004", cwd: "/w/p")

    func testPayloadParsesHost() { XCTAssertEqual(ev("Stop", host: true).host, want); XCTAssertNil(ev("Stop", host: false).host) }

    func testRowKeepsLatestNonNilAndDoneItemCarriesIt() {
        let m = NotchModel()
        m.apply(ev("UserPromptSubmit", host: true))
        m.apply(ev("PostToolUse", host: false))
        m.apply(ev("Stop", host: false))
        XCTAssertEqual(m.sessions[0].host, want)
        XCTAssertEqual(m.doneItems[0].host, want)
    }

    func testTTYOnlyReportKeepsKnownHost() {
        let m = NotchModel()
        m.apply(ev("UserPromptSubmit", host: true))
        m.apply(payload(["session_id": "s", "cwd": "/w/p", "hook_event_name": "Stop", "chippy_branch": "b", "chippy_tty": "ttys009"]))
        XCTAssertEqual(m.doneItems[0].host, want)
    }

    func testNoHostMeansNoButton() {
        let m = NotchModel()
        m.apply(ev("Stop", host: false))
        XCTAssertNil(m.doneItems[0].host)
    }
}
