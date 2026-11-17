import XCTest
@testable import ChippyCore

final class SleepDisablerTests: XCTestCase {
    var marker: URL!
    var calls: [Bool] = []
    var pending: [(Bool) -> Void] = []   // completions held to simulate a slow sudo

    override func setUp() {
        marker = FileManager.default.temporaryDirectory.appendingPathComponent("chippy-\(UUID().uuidString)/disablesleep-on")
        calls = []; pending = []
    }
    func make() -> SleepDisabler {
        SleepDisabler(marker: marker) { [unowned self] on, done in self.calls.append(on); self.pending.append(done) }
    }
    var markerExists: Bool { FileManager.default.fileExists(atPath: marker.path) }

    func testMarkerWrittenBeforeOneIsIssued() {
        var existedAtCall = false
        let d = SleepDisabler(marker: marker) { [unowned self] _, done in existedAtCall = self.markerExists; done(true) }
        d.set(true)
        XCTAssertTrue(existedAtCall)
        XCTAssertTrue(d.isOn)
    }
    func testOnlyOneCallPerTransitionWhileSlow() {
        let d = make()
        XCTAssertTrue(d.set(true))
        XCTAssertFalse(d.set(true))   // re-entry from timer / sink: dropped
        XCTAssertFalse(d.set(false))  // nested clear (battery dropped): dropped, cannot remove the marker
        XCTAssertEqual(calls, [true])
        XCTAssertTrue(markerExists)
        pending.removeFirst()(true)
        XCTAssertTrue(d.isOn); XCTAssertTrue(markerExists)
    }
    func testClearAfterOnKeepsMarkerUntilZeroSucceeds() {
        let d = make()
        var idle = 0
        d.onIdle = { idle += 1 }
        d.set(true); pending.removeFirst()(true)
        XCTAssertTrue(d.set(false))
        XCTAssertTrue(markerExists)       // still there while the 0 is in flight
        pending.removeFirst()(true)
        XCTAssertFalse(markerExists); XCTAssertFalse(d.isOn); XCTAssertEqual(idle, 2)
    }
    func testFailedClearKeepsMarkerAndReportsStuck() {
        let d = make()
        d.set(true); pending.removeFirst()(true)
        d.set(false); pending.removeFirst()(false)
        XCTAssertTrue(markerExists)
        XCTAssertTrue(d.clearFailed); XCTAssertTrue(d.isStuck); XCTAssertTrue(d.isOn)
    }
    func testFailedOnRemovesMarker() {
        let d = make()
        d.set(true); pending.removeFirst()(false)
        XCTAssertFalse(markerExists); XCTAssertFalse(d.isOn); XCTAssertFalse(d.isStuck)
    }
    func testLeftoverMarkerAtLaunchIsStuckUntilCleared() {
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        let d = make()
        XCTAssertTrue(d.isStuck)
        XCTAssertTrue(d.set(false))
        XCTAssertEqual(calls, [false])
        pending.removeFirst()(true)
        XCTAssertFalse(markerExists); XCTAssertFalse(d.isStuck)
    }
    func testNoCallWhenNothingToClear() {
        let d = make()
        XCTAssertTrue(d.set(false))
        XCTAssertEqual(calls, [])
    }
    func testClearBlockingFailureKeepsMarker() {
        let d = make()
        d.set(true); pending.removeFirst()(true)
        d.clearBlocking { _ in false }
        XCTAssertTrue(markerExists); XCTAssertTrue(d.clearFailed)
        d.clearBlocking { _ in true }
        XCTAssertFalse(markerExists); XCTAssertFalse(d.isStuck)
    }
}
