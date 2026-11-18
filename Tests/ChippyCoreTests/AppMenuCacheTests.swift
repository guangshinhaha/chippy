import XCTest
@testable import ChippyCore

final class AppMenuCacheTests: XCTestCase {
    private let a = [CGRect(x: 10, y: 0, width: 40, height: 24)]

    func testEmptyReadKeepsLastGoodForSameApp() {
        var c = AppMenuCache()
        XCTAssertEqual(c.update(pid: 1, read: a, trusted: true), a)
        XCTAssertEqual(c.update(pid: 1, read: nil, trusted: true), a)
        XCTAssertEqual(c.update(pid: 1, read: [], trusted: true), a)
    }

    func testDifferentAppDropsIt() {
        var c = AppMenuCache()
        c.update(pid: 1, read: a, trusted: true)
        XCTAssertNil(c.update(pid: 2, read: nil, trusted: true))
        XCTAssertEqual(c.update(pid: 2, read: a, trusted: true), a)
    }

    func testLosingTrustDropsIt() {
        var c = AppMenuCache()
        c.update(pid: 1, read: a, trusted: true)
        XCTAssertNil(c.update(pid: 1, read: a, trusted: false))
    }
}
