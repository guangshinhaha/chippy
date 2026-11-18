import XCTest
@testable import ChippyCore

final class GapGateTests: XCTestCase {
    private func eq(_ a: GapGate.Gap?, _ l: CGFloat, _ r: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("expected an apply", file: file, line: line) }
        XCTAssertTrue(MenuBarGap.same(a, (l, r)), "\(a) != (\(l), \(r))", file: file, line: line)
    }

    func testStableReadingAppliesAfterStability() {
        var g = GapGate()
        XCTAssertNil(g.observe((100, 200), now: 10))
        XCTAssertNil(g.poll(now: 10.3))
        eq(g.poll(now: 10.5), 100, 200)
        XCTAssertFalse(g.hasPending)
    }

    func testLaunchRaceSkippedApplyLandsLater() {
        var g = GapGate()
        g.densityChanged(expanded: false, now: 10)        // density settles at launch
        XCTAssertNil(g.observe((100, 200), now: 10.1))
        XCTAssertNil(g.poll(now: 10.6))                   // stable, but within 0.8s of the density change
        XCTAssertNil(g.observe((100, 200), now: 10.7))    // same reading again must not drop the pending apply
        eq(g.poll(now: 10.9), 100, 200)
    }

    func testExpandedThenCollapsed() {
        var g = GapGate()
        g.densityChanged(expanded: true, now: 0)
        XCTAssertNil(g.observe((80, 150), now: 5))
        XCTAssertNil(g.poll(now: 9))                      // card open: stays pending
        XCTAssertNil(g.observe((80, 150), now: 9.5))
        eq(g.densityChanged(expanded: false, now: 10), 80, 150) // rides along with the density change
        XCTAssertFalse(g.hasPending)
    }

    func testUnstableReadingIsNotAppliedOnCollapse() {
        var g = GapGate()
        g.densityChanged(expanded: true, now: 0)
        g.observe((80, 150), now: 5)
        XCTAssertNil(g.densityChanged(expanded: false, now: 5.2)) // not yet stable for 0.4s
        eq(g.poll(now: 6.1), 80, 150)
    }

    func testFlappingReadingRestartsStability() {
        var g = GapGate()
        g.observe((100, 200), now: 10)
        g.observe((300, 200), now: 10.3)                  // changed: timer restarts
        XCTAssertNil(g.poll(now: 10.5))
        eq(g.poll(now: 10.8), 300, 200)
    }

    func testReturningToAppliedClearsPending() {
        var g = GapGate(applied: (100, 200))
        g.observe((300, 200), now: 1)
        XCTAssertTrue(g.hasPending)
        XCTAssertNil(g.observe((101, 200), now: 1.2))
        XCTAssertFalse(g.hasPending)
        XCTAssertNil(g.poll(now: 5))
    }

    func testSameReadingAfterSkippedApplyStillApplies() {
        var g = GapGate()
        g.densityChanged(expanded: true, now: 0)
        g.observe((90, 90), now: 1)
        g.poll(now: 3)                                    // skipped
        g.densityChanged(expanded: false, now: 4)         // applied here
        XCTAssertNil(g.observe((90, 90), now: 5))         // equals applied: nothing more to do
        XCTAssertTrue(MenuBarGap.same(g.applied, (90, 90)))
    }

    func testPlausibleFiltersFramesBeforeGeometry() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let bar = CGRect(x: 0, y: 0, width: 1512, height: 24)       // full-width bar
        let tall = CGRect(x: 100, y: 0, width: 30, height: 80)      // taller than the menu bar
        let elsewhere = CGRect(x: 1600, y: 0, width: 30, height: 24) // another display
        let ok = CGRect(x: 1300, y: 0, width: 30, height: 24)
        XCTAssertEqual(MenuBarGap.plausible([bar, tall, elsewhere, ok], screen: screen, menuBarHeight: 34), [ok])
    }
}
