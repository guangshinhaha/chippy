import XCTest
@testable import ChippyCore

private func payload(_ o: [String: Any]) -> HookPayload {
    HookPayload(json: try! JSONSerialization.data(withJSONObject: o))!
}

/// Issue #138: the notch's "Open T3 Code" button opens the session's own thread via T3's `t3code://threads/<env>/<thread>` link.
final class T3LinkTests: XCTestCase {
    let env = "145c4fbf-3b28-4db5-b919-146ad850bb7e"
    let thread = "b7971675-6db6-4762-a036-05cdbcfed27a"

    // MARK: ids from the environment and the file are validated before they reach a URL

    func testValidIdAcceptsUUIDsAndSlugs() {
        XCTAssertEqual(T3Link.validId(thread), thread)
        XCTAssertEqual(T3Link.validId("abc_DEF-123"), "abc_DEF-123")
    }

    func testValidIdRejectsMissingEmptyAndMalformed() {
        XCTAssertNil(T3Link.validId(nil))
        XCTAssertNil(T3Link.validId(""))
        XCTAssertNil(T3Link.validId("a/b"))
        XCTAssertNil(T3Link.validId("a b"))
        XCTAssertNil(T3Link.validId("a?x=1"))
        XCTAssertNil(T3Link.validId("a\nb"))
        XCTAssertNil(T3Link.validId("thread:subagent:e4ce09d066a35158"))
        XCTAssertNil(T3Link.validId(String(repeating: "a", count: 129)))
        XCTAssertEqual(T3Link.validId(String(repeating: "a", count: 128))?.count, 128)
    }

    func testEnvironmentIdFileIsTrimmed() {
        XCTAssertEqual(T3Link.environmentId(fileContents: env + "\n"), env)
        XCTAssertEqual(T3Link.environmentId(fileContents: "  " + env + " \r\n"), env)
        XCTAssertNil(T3Link.environmentId(fileContents: nil))
        XCTAssertNil(T3Link.environmentId(fileContents: "\n"))
        XCTAssertNil(T3Link.environmentId(fileContents: "not an id\nsecond line"))
    }

    // MARK: URL construction

    func testURLPointsAtTheExactThread() {
        XCTAssertEqual(T3Link.url(environmentId: env, threadId: thread)?.absoluteString, "t3code://threads/\(env)/\(thread)")
    }

    func testNoURLWithoutBothIds() {
        XCTAssertNil(T3Link.url(environmentId: nil, threadId: thread))
        XCTAssertNil(T3Link.url(environmentId: env, threadId: nil))
        XCTAssertNil(T3Link.url(environmentId: env, threadId: "bad/id"))
        XCTAssertNil(T3Link.url(environmentId: "bad id", threadId: thread))
    }

    // MARK: only T3 Code, only with a thread

    func testOnlyT3CodeWithAThreadIdGetsALink() {
        let t3 = HostInfo(pid: 1, bundle: "com.t3tools.t3code", tty: nil, env: ["T3CODE_THREAD_ID": thread])
        XCTAssertEqual(T3Link.threadId(for: t3), thread)
        XCTAssertNil(T3Link.threadId(for: HostInfo(pid: 1, bundle: "com.t3tools.t3code", tty: nil)))
        XCTAssertNil(T3Link.threadId(for: HostInfo(pid: 1, bundle: "com.apple.Terminal", tty: "ttys001", env: ["T3CODE_THREAD_ID": thread])))
        XCTAssertNil(T3Link.threadId(for: nil))
    }
}

/// The relay forwards `T3CODE_THREAD_ID`; the payload keeps only a valid one, and it survives to the Recent item.
final class T3ThreadCarryTests: XCTestCase {
    let thread = "b7971675-6db6-4762-a036-05cdbcfed27a"

    func ev(_ name: String, thread t: Any? = nil) -> HookPayload {
        var o: [String: Any] = ["session_id": "s", "cwd": "/w/p", "hook_event_name": name, "chippy_branch": "b",
                                "chippy_host_pid": 4242, "chippy_host_bundle": "com.t3tools.t3code"]
        if let t { o["chippy_env"] = ["T3CODE_THREAD_ID": t] }
        return payload(o)
    }

    func testPayloadParsesAValidThreadId() { XCTAssertEqual(ev("Stop", thread: thread).host?.env["T3CODE_THREAD_ID"], thread) }

    func testPayloadDropsMissingOrMalformedThreadId() {
        XCTAssertNil(ev("Stop").host?.env["T3CODE_THREAD_ID"])
        XCTAssertNil(ev("Stop", thread: "a/../b").host?.env["T3CODE_THREAD_ID"])
        XCTAssertNil(ev("Stop", thread: 42).host?.env["T3CODE_THREAD_ID"])
        XCTAssertNotNil(ev("Stop", thread: "a/../b").host, "the host itself is still known")
    }

    func testThreadIdSurvivesToTheRecentItem() {
        let m = NotchModel()
        m.apply(ev("UserPromptSubmit", thread: thread))
        m.apply(payload(["session_id": "s", "cwd": "/w/p", "hook_event_name": "PostToolUse", "chippy_branch": "b"]))
        m.apply(payload(["session_id": "s", "cwd": "/w/p", "hook_event_name": "Stop", "chippy_branch": "b"]))
        XCTAssertEqual(m.doneItems[0].host?.env["T3CODE_THREAD_ID"], thread)
        XCTAssertEqual(RecentItem(m.doneItems[0], label: RepoLabel(repo: "p"), resolved: true).host?.env["T3CODE_THREAD_ID"], thread)
    }
}
