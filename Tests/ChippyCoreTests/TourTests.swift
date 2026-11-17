import XCTest
@testable import ChippyCore

final class TourTests: XCTestCase {
    func testStepOrder() { XCTAssertEqual(Tour.steps, [.approval, .question, .done]) }

    func testCaptionsOnlyOnDemoSessions() {
        for s in Tour.steps {
            XCTAssertNotNil(Tour.caption(sessionId: "demo-a", step: s))
            XCTAssertNil(Tour.caption(sessionId: "abc-123", step: s))
            XCTAssertNil(Tour.caption(sessionId: "my-demo-a", step: s))
        }
    }

    func testCaptionText() {
        XCTAssertTrue(Tour.caption(sessionId: "demo-a", step: .approval)!.contains("Allow or Deny"))
        XCTAssertTrue(Tour.caption(sessionId: "demo-a", step: .question)!.contains("Pick an answer"))
        XCTAssertTrue(Tour.caption(sessionId: "demo-a", step: .done)!.contains("until you dismiss"))
    }

    func testDoneCaptionBecomesConnectPromptWhenNotConnected() {
        XCTAssertEqual(Tour.caption(sessionId: "demo-a", step: .done, connected: false), Tour.notConnectedCaption)
        XCTAssertEqual(Tour.caption(sessionId: "demo-a", step: .approval, connected: false), Tour.caption(sessionId: "demo-a", step: .approval))
    }

    func testHooksConnected() {
        let on = #"{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"\"/A/chippy-hook\" relay --timeout 20"}]}]}}"#
        XCTAssertTrue(Tour.hooksConnected(settingsText: on))
        XCTAssertFalse(Tour.hooksConnected(settingsText: nil))
        XCTAssertFalse(Tour.hooksConnected(settingsText: "not json"))
        XCTAssertFalse(Tour.hooksConnected(settingsText: "{}"))
        // Other events alone don't count: approvals need PermissionRequest.
        XCTAssertFalse(Tour.hooksConnected(settingsText: #"{"hooks":{"Stop":[{"hooks":[{"command":"chippy-hook relay"}]}]}}"#))
        XCTAssertFalse(Tour.hooksConnected(settingsText: #"{"hooks":{"PermissionRequest":[{"hooks":[{"command":"other"}]}]}}"#))
    }

    func testConnectScriptQuotesBinaryAndOnlyRunsInstall() {
        let s = Tour.connectScript(binary: "/Apps/Chip's App/chippy-hook")
        XCTAssertTrue(s.contains("'/Apps/Chip'\\''s App/chippy-hook' install"))
        XCTAssertFalse(s.contains("--yes"))
    }
}
