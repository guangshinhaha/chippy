import XCTest
@testable import ChippyCore

final class SummaryMarkdownTests: XCTestCase {
    func testBoldAndCode() {
        XCTAssertEqual(SummaryMarkdown.inline("Fixed **auth.ts** via `ttl()` now"), [.text("Fixed "), .bold("auth.ts"), .text(" via "), .code("ttl()"), .text(" now")])
    }
    func testUnderscoreBold() { XCTAssertEqual(SummaryMarkdown.inline("a __two words__ c"), [.text("a "), .bold("two words"), .text(" c")]) }
    func testSnakeCaseKept() { XCTAssertEqual(SummaryMarkdown.inline("set SESSION_TTL_MINUTES here"), [.text("set SESSION_TTL_MINUTES here")]) }
    func testMathStarKept() { XCTAssertEqual(SummaryMarkdown.inline("2*3 is 6"), [.text("2*3 is 6")]) }
    func testSingleEmphasisStaysLiteral() {
        for s in ["a *b* and _c_ d", "src/*.swift and **/*.ts", "***x***", "a *b c* d"] { XCTAssertEqual(SummaryMarkdown.inline(s), [.text(s)], s) }
    }
    func testUnmatchedMarkersStayLiteral() {
        XCTAssertEqual(SummaryMarkdown.inline("**oops and `tick"), [.text("**oops and `tick")])
    }
    func testLinkParensBalanced() {
        XCTAssertEqual(SummaryMarkdown.inline("[w](https://x/Foo_(bar)) ok"), [.text("w (https://x/Foo_(bar)) ok")])
    }
    func testSplitTailIsPlainParagraph() {
        let d = SummaryMarkdown.doc("1. " + (1...60).map { "word\($0)" }.joined(separator: " "))!
        guard case .paragraph = d.details[0] else { return XCTFail("tail should be a paragraph") }
    }
    func testMoreAbbreviations() {
        let d = SummaryMarkdown.doc("Asked Dr. Smith and Mr. Jones about the rollout plan, which they approved at 9 a.m. today after a long review of the details. Next.")!
        XCTAssertTrue(d.outcomePlain.hasSuffix("long review of the details."), d.outcomePlain)
    }
    func testLinkKeepsLabelAndUrl() {
        XCTAssertEqual(SummaryMarkdown.inline("see [the PR](https://x.com/a?b=1) now"), [.text("see the PR (https://x.com/a?b=1) now")])
        XCTAssertEqual(SummaryMarkdown.inline("![diagram](http://x/y.png)"), [.text("diagram")])
    }
    func testLoneBracketKept() { XCTAssertEqual(SummaryMarkdown.inline("a[0] and wow!"), [.text("a[0] and wow!")]) }
    func testBullets() {
        let b = SummaryMarkdown.parse("- one\n* two\n1. three\n2) four")
        XCTAssertEqual(b.map(\.plain), ["one", "two", "three", "four"])
        XCTAssertEqual(b[0], .bullet([.text("one")]))
        XCTAssertEqual(b[2], .ordered(1, [.text("three")]))
        XCTAssertEqual(b[3], .ordered(2, [.text("four")]))
    }
    func testHeadingBecomesBoldLine() {
        XCTAssertEqual(SummaryMarkdown.parse("## What changed"), [.heading([.bold("What changed")])])
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
        XCTAssertEqual(d.outcome, [.code("x")]); XCTAssertEqual(d.details, [])
    }
    func testCodeFirstFallsBackToTextLine() {
        let d = SummaryMarkdown.doc("```\nlet a = 1\n```\n\nThat sets a.\n\n- more")!
        XCTAssertEqual(d.outcomePlain, "That sets a.")
        XCTAssertEqual(d.details.map(\.plain), ["let a = 1", "more"])
    }
    func testCodeOnlyOutcomeIsFirstLineClipped() {
        let d = SummaryMarkdown.doc("```\n\n" + String(repeating: "x", count: 500) + "\nsecond\n```")!
        XCTAssertTrue(d.outcomePlain.hasSuffix("…")); XCTAssertEqual(d.outcomePlain.count, SummaryMarkdown.maxOutcome + 1)
        if case .code = d.outcome[0] {} else { XCTFail("outcome should be code") }
        XCTAssertNil(SummaryMarkdown.doc("```\n\n```"))
    }
    func testUnmatchedMarkersAreLinear() {
        for m in ["[", "`", "**", "__", "!["] {
            let t0 = Date()
            _ = SummaryMarkdown.inline(String(repeating: m, count: 20_000 / m.count))
            XCTAssertLessThan(Date().timeIntervalSince(t0), 10.0, "slow for \(m)")
        }
        let t0 = Date()
        _ = SummaryMarkdown.inline(String(repeating: "[a](b ", count: 3_000))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10.0)
    }
    func testDunderAndIntraWordUnderscoresLiteral() {
        XCTAssertEqual(SummaryMarkdown.inline("__init__"), [.text("__init__")])
        XCTAssertEqual(SummaryMarkdown.inline("call __init__ now"), [.text("call __init__ now")])
        XCTAssertEqual(SummaryMarkdown.inline("FOO__BAR and X__Y__Z"), [.text("FOO__BAR and X__Y__Z")])
    }
    func testLoneBracketDoesNotSwallowLink() {
        XCTAssertEqual(SummaryMarkdown.inline("see a[0] and [docs](http://x)"), [.text("see a[0] and docs (http://x)")])
        XCTAssertEqual(SummaryMarkdown.inline("[[a]](u) [x](http://y)"), [.text("[[a]](u) x (http://y)")])
    }
    func testBareUrlLabelNotDuplicated() {
        XCTAssertEqual(SummaryMarkdown.inline("[http://x/1](http://x/1)"), [.text("http://x/1")])
    }
    func testSentenceSplitSkipsAbbreviations() {
        let pad = "Updated the parser for several inputs, e.g. quoted strings and nested lists, so it is faster. "
        let d = SummaryMarkdown.doc(pad + "Next part here.")!
        XCTAssertEqual(d.outcomePlain, "Updated the parser for several inputs, e.g. quoted strings and nested lists, so it is faster.")
        let v = SummaryMarkdown.doc("Bumped the dependency to v2. and then reran the whole suite plus the lint and type checks to confirm it all works. Second sentence goes here.")!
        XCTAssertEqual(v.outcomePlain, "Bumped the dependency to v2. and then reran the whole suite plus the lint and type checks to confirm it all works.")
        let x = SummaryMarkdown.doc("Handled json, yaml, etc. and also a lot more formats than before today, which took a good while to finish properly. Done.")!
        XCTAssertEqual(x.outcomePlain, "Handled json, yaml, etc. and also a lot more formats than before today, which took a good while to finish properly.")
    }
    func testHugeInputBounded() {
        XCTAssertNotNil(SummaryMarkdown.doc(String(repeating: "**a** ", count: 100_000)))
    }

    func testLeadingHeadingIsNotOutcome() {
        let d = SummaryMarkdown.doc("## Summary\n\nFixed the login timeout by raising the TTL.")!
        XCTAssertEqual(d.outcomePlain, "Fixed the login timeout by raising the TTL.")
        XCTAssertEqual(d.details, [.heading([.bold("Summary")])])
        XCTAssertEqual(SummaryMarkdown.doc("# Only")!.outcomePlain, "Only")
    }
    func testInlineTripleBacktickIsNotAFence() {
        let b = SummaryMarkdown.parse("```npm test``` passes\n\nok")
        XCTAssertEqual(b.map(\.plain), ["npm test passes", "ok"])
    }
    func testFenceClosesWithSameCharAndLength() {
        let b = SummaryMarkdown.parse("````\n```\nx\n```\n````\n\n~~~\na\n````\n~~~\nafter")
        XCTAssertEqual(b[0], .code("```\nx\n```"))
        XCTAssertEqual(b[1], .code("a\n````"))
        XCTAssertEqual(b[2].plain, "after")
    }
    func testLoneMarkersStayLiteral() {
        for s in ["_app.tsx", "char*", "foo_", "see _app.tsx and _other", "2*3 and 4*5"] {
            XCTAssertEqual(SummaryMarkdown.inline(s), [.text(s)], s)
        }
    }
    func testSingleWordDunderBold() {
        XCTAssertEqual(SummaryMarkdown.inline("__Important__ now"), [.bold("Important"), .text(" now")])
        XCTAssertEqual(SummaryMarkdown.inline("__init__"), [.text("__init__")])
    }
    func testCodeOnlyNotRepeated() {
        let m = SummaryMarkdown.doc("```\nfirst\nsecond\nthird\n```")!
        XCTAssertEqual(m.outcome, [.code("first")]); XCTAssertEqual(m.details, [.code("second\nthird")])
    }
    func testNoSentenceCutAtWordBoundaryKeepsMarker() {
        let words = (1...60).map { "word\($0)" }.joined(separator: " ")
        let d = SummaryMarkdown.doc("- " + words)!
        XCTAssertTrue(d.outcomePlain.hasSuffix("…"))
        let head = String(d.outcomePlain.dropLast())
        XCTAssertFalse(head.hasSuffix(" "))
        guard case .paragraph(let r) = d.details[0] else { return XCTFail("tail should be a plain paragraph") }
        let tail = r.map(\.string).joined()
        XCTAssertEqual(head + " " + tail, words)
        XCTAssertTrue(tail.hasPrefix("word"))
    }
}
