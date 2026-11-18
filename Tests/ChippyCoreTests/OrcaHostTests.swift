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
    func testLandedNeedsAVisibleWindow() {
        XCTAssertTrue(ActivationOutcome.landed(frontmost: true, windowCount: 2, onScreenCount: 1))
        XCTAssertFalse(ActivationOutcome.landed(frontmost: true, windowCount: 2, onScreenCount: 0))  // windows on another Space
        XCTAssertFalse(ActivationOutcome.landed(frontmost: false, windowCount: 2, onScreenCount: 2))
        XCTAssertTrue(ActivationOutcome.landed(frontmost: true, windowCount: 0, onScreenCount: 0))   // windowless app: frontmost only
        XCTAssertFalse(ActivationOutcome.landed(frontmost: false, windowCount: 0, onScreenCount: 0))
    }

    func testActivationOutcome() {
        XCTAssertTrue(ActivationOutcome.isFrontmost(frontmostPid: 7, target: 7))
        XCTAssertFalse(ActivationOutcome.isFrontmost(frontmostPid: 8, target: 7))
        XCTAssertFalse(ActivationOutcome.isFrontmost(frontmostPid: nil, target: 7))
    }
}
