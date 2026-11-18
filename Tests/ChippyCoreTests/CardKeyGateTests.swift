import XCTest
@testable import ChippyCore

final class CardKeyGateTests: XCTestCase {
    func testHotKeysOnlyForShownCardWithoutFieldFocus() {
        XCTAssertTrue(CardKeyGate.shouldRegisterHotKeys(hasShownCard: true, replyFieldFocused: false))
        XCTAssertFalse(CardKeyGate.shouldRegisterHotKeys(hasShownCard: true, replyFieldFocused: true))
        XCTAssertFalse(CardKeyGate.shouldRegisterHotKeys(hasShownCard: false, replyFieldFocused: false))
    }
    func testEscFoldsUnlessFieldFocused() {
        XCTAssertTrue(CardKeyGate.escShouldFold(replyFieldFocused: false))
        XCTAssertFalse(CardKeyGate.escShouldFold(replyFieldFocused: true))
    }
}

final class FreeTextInvisibleTests: XCTestCase {
    func testEmojiAndVariationSelectorsSurvive() {
        XCTAssertEqual(NotchModel.validFreeText("👨\u{200D}👩\u{200D}👧"), "👨\u{200D}👩\u{200D}👧")
        XCTAssertEqual(NotchModel.validFreeText("❤\u{FE0F}"), "❤\u{FE0F}")
        XCTAssertEqual(NotchModel.validFreeText("क\u{094D}\u{200C}ष"), "क\u{094D}\u{200C}ष")
    }
    func testInvisibleOnlyRefused() {
        XCTAssertNil(NotchModel.validFreeText("\u{200B}"))
        XCTAssertNil(NotchModel.validFreeText("\u{2060}\u{FEFF} "))
    }
    func testLineBreaksShared() {
        for v in NotchModel.lineBreaks { XCTAssertNil(NotchModel.validFreeText("a" + String(Unicode.Scalar(v)!) + "b")) }
    }
}
