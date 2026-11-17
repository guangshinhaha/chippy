import XCTest
@testable import ChippyCore

final class ShortcutGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testIgnoredBeforeGuardElapses() {
        XCTAssertFalse(ShortcutGate.allows(shownAt: t0, now: t0))
        XCTAssertFalse(ShortcutGate.allows(shownAt: t0, now: t0.addingTimeInterval(0.59)))
    }

    func testAllowedAtAndAfterGuard() {
        XCTAssertTrue(ShortcutGate.allows(shownAt: t0, now: t0.addingTimeInterval(0.6)))
        XCTAssertTrue(ShortcutGate.allows(shownAt: t0, now: t0.addingTimeInterval(5)))
    }

    func testNoCardShownMeansIgnored() {
        XCTAssertFalse(ShortcutGate.allows(shownAt: nil, now: t0))
    }

    func testOptionIndexMapping() {
        XCTAssertEqual(ShortcutGate.optionIndex(forKey: 1, optionCount: 3), 0)
        XCTAssertEqual(ShortcutGate.optionIndex(forKey: 3, optionCount: 3), 2)
        XCTAssertNil(ShortcutGate.optionIndex(forKey: 4, optionCount: 3))
        XCTAssertNil(ShortcutGate.optionIndex(forKey: 0, optionCount: 3))
        XCTAssertNil(ShortcutGate.optionIndex(forKey: 10, optionCount: 12))
    }
}
