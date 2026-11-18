import XCTest
@testable import ChippyCore

final class NotchMetricsTests: XCTestCase {
    private let screens: [NotchMetrics] = [.sample14, NotchMetrics(width: 200, height: 38), .none]

    func testMaxSizeHoldsEveryShape() {
        for m in screens {
            let box = m.maxSize
            for d in Density.allCases {
                for tall in [false, true] {
                    for h in [CGFloat(0), 80, 300, 900] {
                        let s = m.size(for: d, tall: tall, contentHeight: h)
                        XCTAssertLessThanOrEqual(s.width, box.width)
                        XCTAssertLessThanOrEqual(s.height, box.height)
                    }
                }
            }
        }
    }

    func testMaxSizeIsDeterminedByWidestAndTallest() {
        XCTAssertEqual(NotchMetrics.sample14.maxSize.width, 185 + 380) // compact wings win on a notch Mac
        XCTAssertEqual(NotchMetrics.none.maxSize.width, 460) // tall done card beats the 380 compact strip
        XCTAssertEqual(NotchMetrics.none.maxSize.height, NotchMetrics.maxExpandedHeight)
    }

    func testNoNotchHasNoWing() {
        XCTAssertFalse(NotchMetrics.none.hasNotch)
        XCTAssertTrue(NotchMetrics.sample14.hasNotch)
        XCTAssertEqual(NotchMetrics.sample14.wing(for: .compact), 190)
    }
}

final class MenuBarGapTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notch = CGRect(x: 663, y: 0, width: 185, height: 32)
    private func item(_ x: CGFloat, _ w: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: w, height: 24) }

    func testNoItemsGivesWholeSide() {
        let g = MenuBarGap.wings(items: [], notch: notch, screen: screen)
        XCTAssertEqual(g.left, 663 - 6); XCTAssertEqual(g.right, 664 - 6)
    }
    func testNearestItemEachSide() {
        let g = MenuBarGap.wings(items: [item(10, 100), item(500, 40), item(900, 30), item(1200, 30)], notch: notch, screen: screen)
        XCTAssertEqual(g.left, 663 - 540 - 6); XCTAssertEqual(g.right, 900 - 848 - 6)
    }
    func testOverlappingItemClampsToZero() {
        let g = MenuBarGap.wings(items: [item(640, 60)], notch: notch, screen: screen)
        XCTAssertEqual(g.left, 0)
    }
    func testItemsBelowMenuBarIgnored() {
        let far = CGRect(x: 600, y: 400, width: 50, height: 20)
        XCTAssertEqual(MenuBarGap.wings(items: [far], notch: notch, screen: screen).left, 657)
    }
    func testNarrowGapFallsBackToCollapsedPill() {
        var m = NotchMetrics.sample14
        m.leftGap = 40; m.rightGap = 300
        XCTAssertFalse(m.compactFits)
        XCTAssertEqual(m.size(for: .compact), m.size(for: .collapsed))
        XCTAssertEqual(m.size(for: .collapsed).width, 185 + 80)
    }
    func testWideGapClampsCompactWing() {
        var m = NotchMetrics.sample14
        m.leftGap = 120; m.rightGap = 200
        XCTAssertTrue(m.compactFits)
        XCTAssertEqual(m.wing(for: .compact), 120)
        m.leftGap = 900; m.rightGap = 900
        XCTAssertEqual(m.wing(for: .compact), 190)
    }
}
