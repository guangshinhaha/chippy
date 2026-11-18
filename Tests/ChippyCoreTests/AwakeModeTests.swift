import XCTest
@testable import ChippyCore

final class AwakeModeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testMigrationMatrix() {
        XCTAssertEqual(AwakePolicy.migrate(enabled: false, lidClosed: false), .off)
        XCTAssertEqual(AwakePolicy.migrate(enabled: false, lidClosed: true), .off)
        XCTAssertEqual(AwakePolicy.migrate(enabled: true, lidClosed: false), .agents)
        XCTAssertEqual(AwakePolicy.migrate(enabled: true, lidClosed: true), .agentsLid)
    }
    func testMissingKeysMigrateToOff() {
        // UserDefaults.bool returns false for missing keys.
        let d = UserDefaults(suiteName: "chippy.test.\(UUID().uuidString)")!
        XCTAssertEqual(AwakePolicy.migrate(enabled: d.bool(forKey: "keepAwake.enabled"),
                                           lidClosed: d.bool(forKey: "keepAwake.lidClosed")), .off)
    }
    func testExpiryBoundary() {
        let until = t0.addingTimeInterval(60)
        XCTAssertEqual(AwakePolicy.effectiveMode(mode: .agents, until: until, now: until.addingTimeInterval(-0.001), setupInstalled: true), .agents)
        XCTAssertEqual(AwakePolicy.effectiveMode(mode: .agents, until: until, now: until, setupInstalled: true), .off)
        XCTAssertEqual(AwakePolicy.effectiveMode(mode: .agentsLid, until: until, now: until.addingTimeInterval(1), setupInstalled: true), .off)
    }
    func testDeadlineAlreadyPassedAtLaunch() {
        XCTAssertEqual(AwakePolicy.effectiveMode(mode: .agentsLid, until: t0.addingTimeInterval(-3600), now: t0, setupInstalled: true), .off)
    }
    func testNoDeadlineNeverExpires() {
        XCTAssertEqual(AwakePolicy.effectiveMode(mode: .agents, until: nil, now: t0.addingTimeInterval(1e9), setupInstalled: false), .agents)
    }
    func testLidModeWithoutSetupFallsBack() {
        XCTAssertEqual(AwakePolicy.effectiveMode(mode: .agentsLid, until: nil, now: t0, setupInstalled: false), .agents)
        XCTAssertEqual(AwakePolicy.effectiveMode(mode: .agentsLid, until: nil, now: t0, setupInstalled: true), .agentsLid)
        XCTAssertEqual(AwakePolicy.effectiveMode(mode: .off, until: nil, now: t0, setupInstalled: false), .off)
    }
    func testParentTitles() {
        XCTAssertEqual(AwakePolicy.parentTitle(mode: .off, until: nil, now: t0), "Keep Mac awake: Off")
        XCTAssertEqual(AwakePolicy.parentTitle(mode: .agents, until: nil, now: t0), "Keep Mac awake: While agents work")
        XCTAssertEqual(AwakePolicy.parentTitle(mode: .agentsLid, until: nil, now: t0), "Keep Mac awake: While agents work, lid closed")
        XCTAssertEqual(AwakePolicy.parentTitle(mode: .agents, until: t0.addingTimeInterval(4800), now: t0), "Keep Mac awake: While agents work · 1h 20m left")
        XCTAssertEqual(AwakePolicy.parentTitle(mode: .agents, until: t0.addingTimeInterval(2700), now: t0), "Keep Mac awake: While agents work · 45m left")
        XCTAssertEqual(AwakePolicy.parentTitle(mode: .agents, until: t0.addingTimeInterval(30), now: t0), "Keep Mac awake: While agents work · <1m left")
        XCTAssertEqual(AwakePolicy.parentTitle(mode: .off, until: t0.addingTimeInterval(3600), now: t0), "Keep Mac awake: Off")
    }
    func testDurationDeadlines() {
        XCTAssertNil(AwakeDuration.indefinite.deadline(from: t0))
        XCTAssertEqual(AwakeDuration.twoHours.deadline(from: t0), t0.addingTimeInterval(7200))
        XCTAssertEqual(AwakeDuration.closest(until: nil, now: t0), .indefinite)
        XCTAssertEqual(AwakeDuration.closest(until: t0.addingTimeInterval(3000), now: t0), .oneHour)
    }
}
