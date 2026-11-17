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
