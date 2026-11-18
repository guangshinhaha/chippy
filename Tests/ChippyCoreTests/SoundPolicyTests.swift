import Darwin
import XCTest
@testable import ChippyCore

final class SoundPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func play(kind: SoundKind = .done, enabled: Bool = true, front: Bool = false, locked: Bool = false,
                      last: Date? = nil, now: Date? = nil) -> Bool {
        SoundPolicy.shouldPlay(kind: kind, enabled: enabled, hostFrontmost: front, locked: locked,
                               lastPlayed: last, now: now ?? t0)
    }

    func testPlaysWhenAllClear() {
        XCTAssertTrue(play(kind: .done))
        XCTAssertTrue(play(kind: .needsYou))
    }

    func testEachMuteReason() {
        XCTAssertFalse(play(enabled: false))
        XCTAssertFalse(play(front: true))
        XCTAssertFalse(play(locked: true))
    }

    func testCooldownBoundary() {
        XCTAssertFalse(play(last: t0, now: t0))
        XCTAssertFalse(play(last: t0, now: t0.addingTimeInterval(1.999)))
        XCTAssertTrue(play(last: t0, now: t0.addingTimeInterval(2)))
        XCTAssertTrue(play(last: t0, now: t0.addingTimeInterval(5)))
    }

    func testCooldownIsPerSessionByCallerLastPlayed() {
        // Session A played at t0; session B never did. The policy only sees each session's own lastPlayed.
        let now = t0.addingTimeInterval(1)
        XCTAssertFalse(play(last: t0, now: now))
        XCTAssertTrue(play(last: nil, now: now))
    }

    func testFrontmostByPid() {
        let h = HostInfo(pid: 10, bundle: "com.a", tty: nil)
        XCTAssertTrue(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 10, frontmostBundle: "com.other"))
        XCTAssertFalse(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 11, frontmostBundle: "com.a"))
    }

    func testFrontmostFallsBackToBundle() {
        let h = HostInfo(pid: nil, bundle: "com.a", tty: nil)
        XCTAssertTrue(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 3, frontmostBundle: "com.a"))
        XCTAssertFalse(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 3, frontmostBundle: "com.b"))
        XCTAssertFalse(SoundPolicy.isHostFrontmost(host: nil, frontmostPid: 3, frontmostBundle: "com.a"))
    }

    // MARK: model hook

    private func ev(_ e: String, session: String = "s1") -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": session, "cwd": "/w/api", "hook_event_name": e]))!
    }

    private func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("always-\(UUID()).json")),
                   log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")))
    }

    func testModelEmitsDoneOnStopOnly() {
        let m = model(); var got: [(SoundKind, String)] = []
        m.onSound = { k, s, _ in got.append((k, s)) }
        m.apply(ev("UserPromptSubmit")); m.apply(ev("PreToolUse")); m.apply(ev("PostToolUse"))
        XCTAssertTrue(got.isEmpty)
        m.apply(ev("Stop"))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.0, .done); XCTAssertEqual(got.first?.1, "s1")
    }

    func testModelEmitsNeedsYouOnApproval() {
        let m = model(); var got: [SoundKind] = []
        m.onSound = { k, _, _ in got.append(k) }
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let p = HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "cwd": "/w/api", "hook_event_name": "PermissionRequest",
            "tool_name": "Bash", "tool_input": ["command": "ls"]]))!
        m.receiveApproval(p, Connection(fd: fds[0]))
        XCTAssertEqual(got, [.needsYou])
    }
}
