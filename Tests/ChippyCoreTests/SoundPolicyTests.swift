import Darwin
import XCTest
@testable import ChippyCore

final class SoundPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func play(kind: SoundKind = .done, enabled: Bool = true, front: Bool = false, locked: Bool = false,
                      last: Date? = nil, now: Date? = nil) -> Bool {
        SoundPolicy.shouldPlay(kind: kind, enabled: enabled, hostFrontmost: front, quiet: locked,
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

    func testNeedsYouBypassesCooldownButDedupes() {
        XCTAssertFalse(play(kind: .needsYou, last: t0, now: t0.addingTimeInterval(0.2)))
        XCTAssertTrue(play(kind: .needsYou, last: t0, now: t0.addingTimeInterval(0.31)))
        XCTAssertTrue(play(kind: .needsYou, last: t0, now: t0.addingTimeInterval(1)))
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
        XCTAssertFalse(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 11, frontmostBundle: "com.other"))
    }

    func testFrontmostFallsBackToBundle() {
        let h = HostInfo(pid: nil, bundle: "com.a", tty: nil)
        XCTAssertTrue(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 3, frontmostBundle: "com.a"))
        XCTAssertFalse(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 3, frontmostBundle: "com.b"))
        XCTAssertFalse(SoundPolicy.isHostFrontmost(host: nil, frontmostPid: 3, frontmostBundle: "com.a"))
    }

    // MARK: T3 Code (#143)
    // Observed on a real T3 session: the hook sends pid 84876 and bundle com.t3tools.t3code (the one Foreground app);
    // T3's helpers are UIElements with bundle com.t3tools.t3code.helper and never go frontmost.

    private let t3Host = HostInfo(pid: 84876, bundle: T3Link.bundleId, tty: nil)

    func testSoundsAreMutedWhileT3IsFrontmost() {
        let frontmost = SoundPolicy.isHostFrontmost(host: t3Host, frontmostPid: 84876, frontmostBundle: T3Link.bundleId)
        XCTAssertTrue(frontmost)
        for kind in [SoundKind.needsYou, .done] {
            XCTAssertFalse(SoundPolicy.shouldPlay(kind: kind, enabled: true, hostFrontmost: frontmost, quiet: false, lastPlayed: nil, now: Date()))
        }
    }

    func testSoundsPlayWhenAnotherAppIsFrontmostOverT3() {
        let frontmost = SoundPolicy.isHostFrontmost(host: t3Host, frontmostPid: 59321, frontmostBundle: "com.apple.iphonesimulator")
        XCTAssertFalse(frontmost)
        for kind in [SoundKind.needsYou, .done] {
            XCTAssertTrue(SoundPolicy.shouldPlay(kind: kind, enabled: true, hostFrontmost: frontmost, quiet: false, lastPlayed: nil, now: Date()))
        }
    }

    func testARestartedT3StillMutesByBundle() {
        XCTAssertTrue(SoundPolicy.isHostFrontmost(host: t3Host, frontmostPid: 90001, frontmostBundle: T3Link.bundleId, pidIsRunningApp: false))
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
        m.onSound = { k, s, _, _ in got.append((k, s)) }
        m.apply(ev("UserPromptSubmit")); m.apply(ev("PreToolUse")); m.apply(ev("PostToolUse"))
        XCTAssertTrue(got.isEmpty)
        m.apply(ev("Stop"))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.0, .done); XCTAssertEqual(got.first?.1, "s1")
    }

    func testModelEmitsNeedsYouOnApproval() {
        let m = model(); var got: [SoundKind] = []
        m.onSound = { k, _, _, _ in got.append(k) }
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let p = HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "cwd": "/w/api", "hook_event_name": "PermissionRequest",
            "tool_name": "Bash", "tool_input": ["command": "ls"]]))!
        m.receiveApproval(p, Connection(fd: fds[0]))
        XCTAssertEqual(got, [.needsYou])
    }

    func testKnownPidIgnoresBundle() {
        let h = HostInfo(pid: 10, bundle: "com.a", tty: nil)
        XCTAssertFalse(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 99, frontmostBundle: "com.a"))
    }

    func testPidNotRunningAppFallsBackToBundle() {
        let h = HostInfo(pid: 10, bundle: "com.a", tty: nil)
        XCTAssertTrue(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 99, frontmostBundle: "com.a", pidIsRunningApp: false))
        XCTAssertFalse(SoundPolicy.isHostFrontmost(host: h, frontmostPid: 99, frontmostBundle: "com.b", pidIsRunningApp: false))
    }

    func testCooldownsPerSessionAndKind() {
        var c = SoundCooldowns()
        c.record(.done, session: "a", at: t0)
        XCTAssertEqual(c.lastPlayed(.done, session: "a"), t0)
        XCTAssertNil(c.lastPlayed(.needsYou, session: "a"))   // done does not suppress needs-you
        XCTAssertNil(c.lastPlayed(.done, session: "b"))
        c.prune(session: "a")
        XCTAssertEqual(c.sessionCount, 0)
    }

    func testRepeatStopWithoutActivityIsSilentButNewPromptSounds() {
        let m = model(); var n = 0
        m.onSound = { _, _, _, _ in n += 1 }
        m.apply(ev("Stop")); m.apply(ev("Stop"))
        XCTAssertEqual(n, 1)
        m.apply(ev("UserPromptSubmit")); m.apply(ev("Stop"))
        XCTAssertEqual(n, 2)
    }

    func testAgentWorktreeStopIsSilent() {
        let m = model(); var n = 0
        m.onSound = { _, _, _, _ in n += 1 }
        let p = HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "w", "cwd": "/r/.claude/worktrees/agent-x", "hook_event_name": "Stop"]))!
        XCTAssertTrue(p.isAgentWorktree)
        m.apply(p)
        XCTAssertEqual(n, 0)
    }

    func testSessionEndFiresCallback() {
        let m = model(); var ended: [String] = []
        m.onSessionEnd = { ended.append($0) }
        m.apply(ev("SessionEnd"))
        XCTAssertEqual(ended, ["s1"])
    }

    private func approval(_ m: NotchModel, tool: String, input: [String: Any]) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let p = HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "cwd": "/w/api", "hook_event_name": "PermissionRequest",
            "tool_name": tool, "tool_input": input]))!
        m.receiveApproval(p, Connection(fd: fds[0]))
    }

    func testAskUserQuestionSoundsNeedsYou() {
        let m = model(); var got: [SoundKind] = []
        m.onSound = { k, _, _, _ in got.append(k) }
        approval(m, tool: "AskUserQuestion", input: ["questions": [["question": "Which?", "header": "H", "multiSelect": false,
                 "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]]]])
        XCTAssertEqual(m.pending.count, 1)
        XCTAssertEqual(got, [.needsYou])
    }

    func testAutoAllowedApprovalIsSilent() {
        let store = AlwaysStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("always-\(UUID()).json"))
        let p = HookPayload(json: try! JSONSerialization.data(withJSONObject: [
            "session_id": "s1", "cwd": "/w/api", "hook_event_name": "PermissionRequest",
            "tool_name": "Bash", "tool_input": ["command": "ls"]]))!
        store.insert(PendingRequest(payload: p))
        let m = NotchModel(always: store, log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ev-\(UUID()).jsonl")))
        var n = 0
        m.onSound = { _, _, _, _ in n += 1 }
        approval(m, tool: "Bash", input: ["command": "ls"])
        XCTAssertEqual(n, 0)
        XCTAssertTrue(m.pending.isEmpty)
    }
}
