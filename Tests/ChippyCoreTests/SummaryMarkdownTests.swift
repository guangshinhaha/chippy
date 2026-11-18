import XCTest
@testable import ChippyCore

final class SummaryMarkdownTests: XCTestCase {
    func testBoldAndCode() {
        XCTAssertEqual(SummaryMarkdown.inline("Fixed **auth.ts** via `ttl()` now"), [.text("Fixed "), .bold("auth.ts"), .text(" via "), .code("ttl()"), .text(" now")])
    }
    func testUnderscoreBold() { XCTAssertEqual(SummaryMarkdown.inline("a __b__ c"), [.text("a "), .bold("b"), .text(" c")]) }
    func testSnakeCaseKept() { XCTAssertEqual(SummaryMarkdown.inline("set SESSION_TTL_MINUTES here"), [.text("set SESSION_TTL_MINUTES here")]) }
    func testMathStarKept() { XCTAssertEqual(SummaryMarkdown.inline("2*3 is 6"), [.text("2*3 is 6")]) }
    func testSingleEmphasisDropped() { XCTAssertEqual(SummaryMarkdown.inline("a *b* and _c_ d"), [.text("a b and c d")]) }
    func testUnmatchedMarkersDropped() {
        XCTAssertEqual(SummaryMarkdown.inline("**oops and `tick"), [.text("oops and tick")])
    }
    func testLinkKeepsLabelOnly() {
        XCTAssertEqual(SummaryMarkdown.inline("see [the PR](https://x.com/a?b=1) now"), [.text("see the PR now")])
        XCTAssertEqual(SummaryMarkdown.inline("![diagram](http://x/y.png)"), [.text("diagram")])
    }
    func testLoneBracketKept() { XCTAssertEqual(SummaryMarkdown.inline("a[0] and wow!"), [.text("a[0] and wow!")]) }
    func testBullets() {
        let b = SummaryMarkdown.parse("- one\n* two\n1. three\n2) four")
        XCTAssertEqual(b.map(\.plain), ["one", "two", "three", "four"])
        XCTAssertTrue(b.allSatisfy { if case .bullet = $0 { return true } else { return false } })
    }
    func testHeadingBecomesBoldLine() {
        XCTAssertEqual(SummaryMarkdown.parse("## What changed"), [.paragraph([.bold("What changed")])])
    }
    func testParagraphsJoinAndSplit() {
        XCTAssertEqual(SummaryMarkdown.parse("a\nb\n\nc").map(\.plain), ["a b", "c"])
    }
    func testFencedCodeKeptRawAndCapped() {
        let code = (1...20).map { "line\($0)" }.joined(separator: "\n")
        let b = SummaryMarkdown.parse("```swift\n**x**\n```\n\n```\n\(code)\n```")
        XCTAssertEqual(b[0], .code("**x**"))
        XCTAssertTrue(b[1].plain.hasSuffix("\n…"))
        XCTAssertEqual(b[1].plain.components(separatedBy: "\n").count, 13)
    }
    func testUnclosedFenceIsCode() { XCTAssertEqual(SummaryMarkdown.parse("hi\n```\nlet a = 1"), [.paragraph([.text("hi")]), .code("let a = 1")]) }
    func testRuleAndQuoteMarkersGone() {
        XCTAssertEqual(SummaryMarkdown.parse("---\n> quoted\n***").map(\.plain), ["quoted"])
    }
    func testNoRawMarkersSurvive() {
        let md = "# T\n\nDone **now**, see [x](http://u) and `c`.\n\n- **a**: `b`\n- _c_ d"
        for b in SummaryMarkdown.parse(md) {
            for bad in ["**", "`", "](", "# "] { XCTAssertFalse(b.plain.contains(bad), "\(bad) in \(b.plain)") }
        }
    }
    func testDocOutcomeFirstThenDetails() {
        let d = SummaryMarkdown.doc("Fixed the timeout.\n\nWhat changed:\n- a\n- b")!
        XCTAssertEqual(d.outcomePlain, "Fixed the timeout.")
        XCTAssertEqual(d.details.map(\.plain), ["What changed:", "a", "b"])
    }
    func testLongFirstParagraphSplitsAtSentence() {
        let long = "Fixed the login timeout by raising the TTL. " + String(repeating: "More detail follows here. ", count: 12)
        let d = SummaryMarkdown.doc(long)!
        XCTAssertEqual(d.outcomePlain, "Fixed the login timeout by raising the TTL.")
        XCTAssertTrue(d.details[0].plain.hasPrefix("More detail"))
    }
    func testLongSentenceFreeTextIsCapped() {
        let d = SummaryMarkdown.doc(String(repeating: "word ", count: 100))!
        XCTAssertLessThanOrEqual(d.outcomePlain.count, SummaryMarkdown.maxOutcome + 1)
        XCTAssertTrue(d.outcomePlain.hasSuffix("…"))
        XCTAssertFalse(d.details.isEmpty)
    }
    func testNilEmptyAndCodeOnly() {
        XCTAssertNil(SummaryMarkdown.doc(nil)); XCTAssertNil(SummaryMarkdown.doc(" \n\n "))
        let d = SummaryMarkdown.doc("```\nx\n```")!
        XCTAssertTrue(d.outcome.isEmpty); XCTAssertEqual(d.details, [.code("x")])
    }
    func testHugeInputBounded() {
        XCTAssertNotNil(SummaryMarkdown.doc(String(repeating: "**a** ", count: 100_000)))
    }
}
