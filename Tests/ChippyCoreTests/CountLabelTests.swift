import XCTest
@testable import ChippyCore

/// Issue #212: "+N" and "All N" cap at "99+" so the compact notch cannot widen.
final class CountLabelTests: XCTestCase {
    func testBelowAndAtCapShowsTheNumber() {
        XCTAssertEqual(CountLabel.short(0), "0")
        XCTAssertEqual(CountLabel.short(1), "1")
        XCTAssertEqual(CountLabel.short(99), "99")
    }

    func testAboveCapShowsCapPlus() {
        XCTAssertEqual(CountLabel.short(100), "99+")
        XCTAssertEqual(CountLabel.short(119), "99+")
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(CountLabel.short(-1), "0")
        XCTAssertEqual(CountLabel.short(Int.min), "0")
    }

    func testCustomCapBoundary() {
        XCTAssertEqual(CountLabel.short(9, cap: 9), "9")
        XCTAssertEqual(CountLabel.short(10, cap: 9), "9+")
    }

    func testIntMaxDoesNotCrash() {
        XCTAssertEqual(CountLabel.short(Int.max), "99+")
    }

    func testCountedSingularOnlyAtOne() {
        XCTAssertEqual(CountLabel.counted(0, "session"), "0 sessions")
        XCTAssertEqual(CountLabel.counted(1, "session"), "1 session")
        XCTAssertEqual(CountLabel.counted(2, "session"), "2 sessions")
        XCTAssertEqual(CountLabel.counted(1, "second"), "1 second")
        XCTAssertEqual(CountLabel.counted(1, "more line"), "1 more line")
        XCTAssertEqual(CountLabel.counted(3, "hidden character"), "3 hidden characters")
        XCTAssertEqual(CountLabel.counted(2, "entry", plural: "entries"), "2 entries")
    }
}
