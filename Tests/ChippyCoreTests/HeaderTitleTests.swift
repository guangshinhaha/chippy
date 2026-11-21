import Darwin
import XCTest
@testable import ChippyCore

/// Issue #96: the header describes what the body shows, not the overall state.
/// Precedence: list > pending card > jumped-to done detail > Recent > terminal chips > done chips > state.
final class HeaderTitleTests: XCTestCase {
    private func model() -> NotchModel {
        let log = scratchURL("ht-\(UUID()).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: log) }
        return NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: log))
    }
    private func hook(_ ev: String, _ sid: String) -> HookPayload {
        HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"\#(ev)","cwd":"/Users/x/repos/api-server","chippy_branch":"main"}"#.utf8))!
    }
    private func perm(_ tool: String, _ input: [String: Any], sid: String) -> HookPayload {
        HookPayload(json: try! JSONSerialization.data(withJSONObject: ["session_id": sid, "hook_event_name": "PermissionRequest",
            "cwd": "/Users/x/repos/api-server", "chippy_branch": "main", "tool_name": tool, "tool_input": input]))!
    }
    private let multi: [String: Any] = ["questions": [["question": "Q?", "header": "h", "multiSelect": true,
                                                       "options": [["label": "A, x", "description": "a"], ["label": "B", "description": "b"]]]]]
    private func pair() -> Connection {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let far = fds[1]
        addTeardownBlock { close(far) }
        return Connection(fd: fds[0])
    }
    private func finish(_ m: NotchModel, _ sid: String) { m.apply(hook("UserPromptSubmit", sid)); m.apply(hook("Stop", sid)) }
    private func terminalChip(_ m: NotchModel, sid: String) { m.receiveApproval(perm("AskUserQuestion", multi, sid: sid), Connection.detached()) }

    func testFinishedCardWhileAnotherSessionWorksSaysDoneNotWorking() {
        let m = model()
        finish(m, "a")
        m.apply(hook("UserPromptSubmit", "b"))
        m.toggleOpen()
        XCTAssertEqual(m.state, .working)
        XCTAssertEqual(m.headerTitle, "Done")
    }

    func testNoChipsFallsBackToState() {
        let m = model()
        m.apply(hook("UserPromptSubmit", "b"))
        XCTAssertEqual(m.headerTitle, "Working")
    }

    func testTerminalChipIsPassiveSoNeverNeedsYou() {
        let m = model()
        terminalChip(m, sid: "t")
        m.toggleOpen()
        XCTAssertEqual(m.state, .needsYou)               // the icon still asks for attention
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.headerTitle, "Asked in terminal")
    }

    func testTerminalBeatsDone() {
        let m = model()
        finish(m, "a"); terminalChip(m, sid: "t")
        m.toggleOpen()
        XCTAssertEqual(m.headerTitle, "Asked in terminal")
    }

    func testTerminalChipWhileAnotherSessionWorks() {
        let m = model()
        terminalChip(m, sid: "t"); m.apply(hook("UserPromptSubmit", "b"))
        m.toggleOpen()
        XCTAssertEqual(m.headerTitle, "Asked in terminal")
    }

    func testPendingBeatsTerminalAndDone() {
        let m = model()
        finish(m, "a"); terminalChip(m, sid: "t")
        m.receiveApproval(perm("Bash", ["command": "ls"], sid: "p"), pair())
        XCTAssertNotNil(m.shownPending)
        XCTAssertEqual(m.headerTitle, "Needs you")
    }

    func testTwoPendingShowPosition() {
        let m = model()
        m.receiveApproval(perm("Bash", ["command": "ls"], sid: "p1"), pair())
        m.receiveApproval(perm("Bash", ["command": "pwd"], sid: "p2"), pair())
        XCTAssertEqual(m.headerTitle, "Needs you · 1 of 2")
    }

    func testListOpenSaysWaiting() {
        let m = model()
        finish(m, "a"); terminalChip(m, sid: "t")
        m.openList()
        XCTAssertEqual(m.headerTitle, "Waiting · \(m.waitingItems.count)")
    }

    func testJumpedToDoneDetailSaysDoneEvenWithTerminalChip() {
        let m = model()
        terminalChip(m, sid: "t"); finish(m, "a")
        m.openList(); m.activate(.done("a"))
        XCTAssertEqual(m.headerTitle, "Done")
    }

    func testJumpedToDoneDetailWhilePendingSaysFinished() {
        let m = model()
        finish(m, "a")
        m.receiveApproval(perm("Bash", ["command": "ls"], sid: "p"), pair())
        m.openList(); m.activate(.done("a"))
        XCTAssertEqual(m.headerTitle, "Finished")
    }

    func testRestOpenWithNothingGoingOnSaysAllQuiet() {
        let m = model()
        m.toggleOpen()
        XCTAssertTrue(m.restOpen)
        XCTAssertEqual(m.headerTitle, "All quiet")
    }

    func testRestOpenWithTerminalChipFollowsTheChip() {
        let m = model()
        m.toggleOpen()                                   // panel opened from rest
        terminalChip(m, sid: "t")                        // a passive chip joins the open panel
        XCTAssertTrue(m.restOpen)
        XCTAssertEqual(m.headerTitle, "1 needs you", "the open panel counts what needs you; it no longer names a chip")
    }
}
