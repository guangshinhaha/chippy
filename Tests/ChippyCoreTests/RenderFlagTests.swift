import XCTest
@testable import ChippyCore

/// Issue #223: an unrecognised `--render-*` flag fails fast instead of launching the full app.
final class RenderFlagTests: XCTestCase {
    func testKnownFlagWithOutputRenders() {
        XCTAssertEqual(RenderFlag.parse(["Chippy", "--render-plan", "out.png"]), .render(flag: "--render-plan", output: "out.png"))
        for f in RenderFlag.known {
            XCTAssertEqual(RenderFlag.parse(["Chippy", f, "x.png"]), .render(flag: f, output: "x.png"))
        }
    }

    func testUnknownFlagIsAnError() {
        XCTAssertEqual(RenderFlag.parse(["Chippy", "--render-x", "out.png"]), .unknown("--render-x"))
        XCTAssertEqual(RenderFlag.parse(["Chippy", "--render-", "out.png"]), .unknown("--render-"))
    }

    func testOneStringWithSeveralFlagsIsAnError() {
        let joined = "--render-gallery --render-tab"
        XCTAssertEqual(RenderFlag.parse(["Chippy", joined, "out.png"]), .unknown(joined))
    }

    func testNoRenderFlagLaunches() {
        XCTAssertEqual(RenderFlag.parse(["Chippy"]), .none)
        XCTAssertEqual(RenderFlag.parse([]), .none)
        XCTAssertEqual(RenderFlag.parse(["Chippy", "-NSDocumentRevisionsDebugMode", "YES"]), .none)
    }

    func testKnownFlagWithoutOutputIsAnError() {
        XCTAssertEqual(RenderFlag.parse(["Chippy", "--render-tab"]), .missingOutput("--render-tab"))
    }

    func testUsageListsEveryValidFlag() {
        let text = RenderFlag.usage(.unknown("--render-x"))
        XCTAssertTrue(text.contains("--render-x"))
        for f in RenderFlag.known { XCTAssertTrue(text.contains(f)) }
    }
}
