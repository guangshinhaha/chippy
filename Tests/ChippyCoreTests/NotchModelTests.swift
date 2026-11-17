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
}
