import XCTest
@testable import ChippyCore

/// Issue #163: the user picks the macOS system sound for each kind; anything unusable falls back to the kind's default.
final class SoundChoiceTests: XCTestCase {
    let installed = ["Basso", "Glass", "Pop", "Submarine", "Tink"]

    func testDefaultsStayPopAndTink() {
        XCTFail("ci probe")
        XCTAssertEqual(SoundChoice.defaultName(.needsYou), "Pop")
        XCTAssertEqual(SoundChoice.defaultName(.done), "Tink")
    }

    func testNoSavedNameGivesTheDefault() {
        XCTAssertEqual(SoundChoice.name(for: .needsYou, saved: nil, installed: installed), "Pop")
        XCTAssertEqual(SoundChoice.name(for: .done, saved: nil, installed: installed), "Tink")
    }

    func testEmptyAndUnknownFallBack() {
        XCTAssertEqual(SoundChoice.name(for: .needsYou, saved: "", installed: installed), "Pop")
        XCTAssertEqual(SoundChoice.name(for: .done, saved: "Gone", installed: installed), "Tink")
    }

    func testAnInstalledNamePassesThroughPerKind() {
        XCTAssertEqual(SoundChoice.name(for: .needsYou, saved: "Glass", installed: installed), "Glass")
        XCTAssertEqual(SoundChoice.name(for: .done, saved: "Submarine", installed: installed), "Submarine")
    }

    func testAKindReadsOnlyItsOwnSetting() {
        let (_, defaults) = scratchDefaults()
        defaults.set("Glass", forKey: SoundChoice.key(.needsYou))
        XCTAssertEqual(SoundChoice.name(for: .needsYou, defaults: defaults, installed: installed), "Glass")
        XCTAssertEqual(SoundChoice.name(for: .done, defaults: defaults, installed: installed), "Tink")
    }

    func testTheChoiceSurvivesARelaunch() {
        let (suite, first) = scratchDefaults()
        first.set("Basso", forKey: SoundChoice.key(.done))
        let again = UserDefaults(suiteName: suite)! // a new handle, as after a relaunch
        XCTAssertEqual(SoundChoice.name(for: .done, defaults: again, installed: installed), "Basso")
    }

    func testTheInstalledListIsSortedNamesWithoutExtension() {
        let files = ["Tink.aiff", "Basso.aiff", ".DS_Store", "notes.txt", "Pop.aiff"]
        XCTAssertEqual(SoundChoice.installedNames(fromFiles: files), ["Basso", "Pop", "Tink"])
    }
}
