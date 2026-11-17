import Darwin
import XCTest
@testable import ChippyCore

/// Issue #52: review follow-ups to the v1.1 PRs.
final class ReviewFollowupTests: XCTestCase {
    private func payload(_ sid: String) -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": sid, "cwd": "/w/api", "hook_event_name": "PermissionRequest",
            "tool_name": "Bash", "tool_input": ["command": "x"]]))!
    }
    private func pair() -> Connection {
        var fds: [Int32] = [0, 0]; socketpair(AF_UNIX, SOCK_STREAM, 0, &fds); return Connection(fd: fds[0])
    }

    // 1. Always on a demo card is never remembered; on a real one it is.
    func testAlwaysIsNotPersistedForDemoSessions() {
        let store = AlwaysStore(url: nil)
        let m = NotchModel(always: store, log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-t-\(UUID()).jsonl")))
        m.receiveApproval(payload("demo-tour"), pair())
        let demo = m.pending[0]
        m.resolve(demo.id, .always)
        XCTAssertFalse(store.contains(demo))
        m.receiveApproval(payload("real"), pair())
        let real = m.pending[0]
        m.resolve(real.id, .always)
        XCTAssertTrue(store.contains(real))
    }

    // 4. Upgrade keeps a custom --timeout; defaults fill only what is missing.
    func testUpgradeKeepsCustomTimeouts() {
        func perm(_ s: [String: Any]) -> [String: Any] {
            let e = ((s["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]])[0]
            return (e["hooks"] as! [[String: Any]])[0]
        }
        let old: [String: Any] = ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [
            ["type": "command", "command": "\"/App/chippy-hook\" relay --timeout 60", "timeout": 70]]]]]]
        let up = perm(SettingsInstaller.merged(old, binary: "/App/chippy-hook", events: ["PermissionRequest"]))
        XCTAssertEqual(up["command"] as? String, "\"/App/chippy-hook\" relay --timeout 60 --question-timeout 120")
        XCTAssertEqual(up["timeout"] as? Int, 130)
        let both: [String: Any] = ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [
            ["type": "command", "command": "\"/App/chippy-hook\" relay --timeout 60 --question-timeout 200", "timeout": 210]]]]]]
        let up2 = perm(SettingsInstaller.merged(both, binary: "/App/chippy-hook", events: ["PermissionRequest"]))
        XCTAssertEqual(up2["command"] as? String, "\"/App/chippy-hook\" relay --timeout 60 --question-timeout 200")
        XCTAssertEqual(up2["timeout"] as? Int, 210)
    }

    // 5. A regular app with no bundle id is skipped; the walk reaches the real terminal.
    func testWalkSkipsAppWithoutBundleId() {
        let parents: [Int32: Int32] = [100: 90, 90: 80, 80: 1]
        let apps: Set<Int32> = [90, 80]                       // both "regular" apps
        let bundles: [Int32: String] = [80: "com.apple.Terminal"] // 90 has none
        let r = ProcessTree.walk(start: 100, parent: { parents[$0] },
                                 isApp: { ProcessTree.isGUIHost(regularApp: apps.contains($0), bundleId: bundles[$0]) },
                                 tty: { _ in nil })
        XCTAssertEqual(r.hostPid, 80)
        XCTAssertFalse(ProcessTree.isGUIHost(regularApp: true, bundleId: nil))
        XCTAssertTrue(ProcessTree.isGUIHost(regularApp: true, bundleId: "x"))
        XCTAssertFalse(ProcessTree.isGUIHost(regularApp: false, bundleId: "x"))
    }

    // 7. Keys follow the current question's option count.
    func testOptionCountFollowsStep() {
        XCTAssertEqual(ShortcutGate.optionCount(step: 0, counts: [4, 2]), 4)
        XCTAssertEqual(ShortcutGate.optionCount(step: 1, counts: [4, 2]), 2)
        XCTAssertEqual(ShortcutGate.optionCount(step: 5, counts: [4, 2]), 2) // clamped like the card
        XCTAssertEqual(ShortcutGate.optionCount(step: 0, counts: []), 0)
    }

    // 3. Parse timestamps once; both windows come from the same parsed list.
    func testDatedParsesOnceAndFiltersTwice() {
        let now = Date()
        let f = ISO8601DateFormatter()
        func e(_ d: Date) -> WaitEvent { WaitEvent(ts: f.string(from: d), waitMs: 1000, channel: .notch, decision: "allow", project: "p", tool: "t") }
        let bad = WaitEvent(ts: "garbage", waitMs: 1, channel: .notch, decision: "x", project: "p", tool: "t")
        let dated = WaitSummary.dated([e(now), e(now.addingTimeInterval(-3 * 86_400)), e(now.addingTimeInterval(-9 * 86_400)), bad])
        XCTAssertEqual(dated.count, 3)
        XCTAssertEqual(WaitSummary(dated: dated, since: now.addingTimeInterval(-3600)).total, 1)
        XCTAssertEqual(WaitSummary(dated: dated, since: now.addingTimeInterval(-7 * 86_400)).total, 2)
    }

    // 8. Empty state keeps its label.
    func testEmptyMenuLinesKeepLabel() {
        XCTAssertEqual(WaitSummary([]).menuLine(label: "Waited on you today"), "Waited on you today: none yet")
        XCTAssertEqual(WaitSummary([]).menuLine(label: "This week", showAsks: true), "This week: none yet")
    }
}
