import XCTest
@testable import ChippyCore

final class NotchModelTests: XCTestCase {
    func testFourV1StatesAndThreeDensities() {
        XCTAssertEqual(ChippyState.allCases.count, 4)
        XCTAssertEqual(Density.allCases.count, 3)
    }

    func testAllStatesReachable() {
        let m = NotchModel()
        for s in ChippyState.allCases { m.state = s; XCTAssertEqual(m.state, s) }
    }

    func testClickOpensSessionListAndSecondClickClosesIt() {
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")))
        m.apply(HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"SessionStart","cwd":"/x/p"}"#.utf8))!)
        XCTAssertEqual(m.density, Density.compact)
        m.toggleOpen(); XCTAssertEqual(m.density, Density.expanded)
        m.toggleOpen(); XCTAssertEqual(m.density, Density.compact)
    }

    func testClickWithNoSessionsStaysCollapsed() {
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")))
        m.toggleOpen()
        XCTAssertEqual(m.density, Density.collapsed)
        XCTAssertFalse(m.pinnedOpen)
    }
}
