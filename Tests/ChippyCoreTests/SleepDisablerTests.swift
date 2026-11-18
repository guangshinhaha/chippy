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
        XCTAssertFalse(markerExists); XCTAssertFalse(d.isOn); XCTAssertEqual(idle, 0)
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

    // MARK: retry floor and quit race
    func testFailingRunnerGetsAtMostOneCallPerFiveSeconds() {
        var clock = Date(timeIntervalSince1970: 1_000)
        var idle = 0
        let d = SleepDisabler(marker: marker, now: { clock }) { [unowned self] on, done in self.calls.append(on); done(false) }
        d.onIdle = { idle += 1 }
        d.set(true)                       // fails
        XCTAssertEqual(idle, 0)           // a failure does not trigger an immediate re-evaluate
        for _ in 0..<50 { d.set(true) }   // burst of evaluate() calls inside the floor
        XCTAssertEqual(calls.count, 1)
        clock = clock.addingTimeInterval(4.9); d.set(true)
        XCTAssertEqual(calls.count, 1)
        clock = clock.addingTimeInterval(0.2); d.set(true)   // past 5s: next tick retries once
        XCTAssertEqual(calls.count, 2)
        for _ in 0..<50 { d.set(true) }
        XCTAssertEqual(calls.count, 2)
    }
    func testSuccessWithDroppedRequestReEvaluatesOnce() {
        let d = make()
        var idle = 0
        d.onIdle = { idle += 1 }
        d.set(true); d.set(false)         // dropped
        pending.removeFirst()(true)
        XCTAssertEqual(idle, 1)
        d.set(false); pending.removeFirst()(true)   // no drop this time
        XCTAssertEqual(idle, 1)
    }
    func testClearBlockingWaitsForInFlightOneThenZeroLeavesMarkerRemoved() {
        var clock = Date(timeIntervalSince1970: 1_000)
        var order: [String] = []
        var pend: [(Bool) -> Void] = []
        let d = SleepDisabler(marker: marker, now: { clock }, pump: { _ in
            clock = clock.addingTimeInterval(0.05)
            if !pend.isEmpty { order.append("1 done"); pend.removeFirst()(true) }   // slow 1 finishes during the wait
        }) { on, done in pend.append(done) }
        d.set(true)
        d.clearBlocking { on in order.append("blocking \(on ? 1 : 0)"); return true }
        XCTAssertEqual(order, ["1 done", "blocking 0"])
        XCTAssertFalse(markerExists); XCTAssertFalse(d.isOn); XCTAssertFalse(d.inFlight)
    }
    func testClearBlockingTimesOutAndKeepsMarkerIfStillInFlight() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let d = SleepDisabler(marker: marker, now: { clock }, pump: { _ in clock = clock.addingTimeInterval(1) }) { _, _ in }
        d.set(true)
        var ran = false
        d.clearBlocking { _ in ran = true; return true }
        XCTAssertTrue(ran)                // best-effort 0 still issued after ~3s
        XCTAssertTrue(markerExists)       // but the marker stays for relaunch recovery
        XCTAssertTrue(d.isStuck)
    }
}
