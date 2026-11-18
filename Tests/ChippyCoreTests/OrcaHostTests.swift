import XCTest
@testable import ChippyCore

/// Issue #64: what the host walk resolves for an Orca-shaped process tree.
final class OrcaHostResolutionTests: XCTestCase {
    // relay 5 -> claude 4 -> orca-provider-exec 3 -> Orca Helper 2 (not a regular app) -> Orca 100 (regular)
    func testSkipsHelperAndResolvesMainApp() {
        let parents: [Int32: Int32] = [5: 4, 4: 3, 3: 2, 2: 100, 100: 1]
        let regular: Set<Int32> = [100]
        let r = ProcessTree.walk(start: 5, parent: { parents[$0] },
                                 isApp: { ProcessTree.isGUIHost(regularApp: regular.contains($0), bundleId: regular.contains($0) ? "com.stablyai.orca" : nil) },
                                 tty: { _ in nil })
        XCTAssertEqual(r.hostPid, 100)
    }
    func testAccessoryOrBundlelessProcessIsNotAHost() {
        XCTAssertFalse(ProcessTree.isGUIHost(regularApp: false, bundleId: "com.stablyai.orca"))
        XCTAssertFalse(ProcessTree.isGUIHost(regularApp: true, bundleId: nil))
    }
    // Sessions under Orca's daemon-host (parent launchd) have no GUI ancestor: no button rather than a wrong one.
    func testDaemonHostedSessionHasNoHost() {
        let parents: [Int32: Int32] = [5: 4, 4: 3, 3: 1]
        let r = ProcessTree.walk(start: 5, parent: { parents[$0] }, isApp: { _ in false }, tty: { _ in "ttys001" })
        XCTAssertNil(r.hostPid); XCTAssertEqual(r.tty, "ttys001")
    }
    func win(_ pid: Int, layer: Int = 0, w: Double = 800, h: Double = 600, on: Bool? = true) -> [String: Any] {
        var d: [String: Any] = ["kCGWindowOwnerPID": pid, "kCGWindowLayer": layer, "kCGWindowBounds": ["Width": w, "Height": h]]
        if let on { d["kCGWindowIsOnscreen"] = on }
        return d
    }
    func testWindowScanFilters() {
        let list = [win(7), win(7, on: false), win(7, on: nil), win(8), win(7, layer: 25), win(7, w: 20, h: 20), win(9)]
        XCTAssertEqual(WindowScan.counts(in: list, pids: [7, 8]), .init(all: 4, onScreen: 2))
        XCTAssertEqual(WindowScan.counts(in: [], pids: [7]), .init(all: 0, onScreen: 0))
        XCTAssertEqual(WindowScan.counts(in: [["junk": 1]], pids: [7]), .init(all: 0, onScreen: 0))
    }
    func testVerdict() {
        typealias A = ActivationOutcome
        XCTAssertEqual(A.verdict(frontmost: true, counts: .init(all: 2, onScreen: 1)), .landed)
        XCTAssertEqual(A.verdict(frontmost: true, counts: .init(all: 2, onScreen: 0)), .offSpace)
        XCTAssertEqual(A.verdict(frontmost: false, counts: .init(all: 2, onScreen: 2)), .notFrontmost)
        XCTAssertEqual(A.verdict(frontmost: true, counts: .init(all: 0, onScreen: 0)), .landedUnverified)
        XCTAssertEqual(A.verdict(frontmost: true, counts: nil), .landedUnverified)
        XCTAssertEqual(A.verdict(frontmost: false, counts: nil), .notFrontmost)
    }

    func testActivationOutcome() {
        XCTAssertTrue(ActivationOutcome.isFrontmost(frontmostPid: 7, target: 7))
        XCTAssertFalse(ActivationOutcome.isFrontmost(frontmostPid: 8, target: 7))
        XCTAssertFalse(ActivationOutcome.isFrontmost(frontmostPid: nil, target: 7))
    }
}
