import Foundation
import XCTest

/// #100: a short done card must hug its content when offered the full 560pt panel. Runs the app's headless
/// `--measure-done` (real NotchView in an offscreen window) and fails if any case is taller than its content needs.
final class CardHeightTests: XCTestCase {
    func testShortDoneCardHugsContent() throws {
        let bundle = Bundle(for: CardHeightTests.self).bundleURL
        let exe = bundle.deletingLastPathComponent().appendingPathComponent("Chippy")
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: exe.path), "Chippy binary not built next to the tests")
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--measure-done"]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "card taller than content:\n\(text)")
    }
}
