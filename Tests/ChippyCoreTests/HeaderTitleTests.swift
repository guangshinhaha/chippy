import XCTest
@testable import ChippyCore

/// Issue #96: the header must describe the session the body shows, not the overall state.
final class HeaderTitleTests: XCTestCase {
    private func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("ht-\(UUID()).jsonl")))
    }
    private func hook(_ ev: String, _ sid: String) -> HookPayload {
        HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"\#(ev)","cwd":"/Users/x/repos/api-server","chippy_branch":"main"}"#.utf8))!
    }

    func testFinishedCardWhileAnotherSessionWorksSaysDoneNotWorking() {
        let m = model()
        m.apply(hook("UserPromptSubmit", "a")); m.apply(hook("Stop", "a"))
        m.apply(hook("UserPromptSubmit", "b")) // b is working, a's finished chip stays
        m.toggleOpen()
        XCTAssertEqual(m.state, .working)      // the notch icon still shows live work
        XCTAssertFalse(m.doneItems.isEmpty)
        XCTAssertEqual(m.headerTitle, "Done")
    }

    func testNoDoneItemsFallsBackToState() {
        let m = model()
        m.apply(hook("UserPromptSubmit", "b"))
        XCTAssertEqual(m.headerTitle, "Working")
    }
}
