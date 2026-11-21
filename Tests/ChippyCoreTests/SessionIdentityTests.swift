import XCTest
@testable import ChippyCore

final class SessionIdentityTests: XCTestCase {
    func testSameRepoSameIdentityAcrossBooks() { // holds absent collisions: a lone repo takes its hash slot in any fresh book
        XCTAssertEqual(IdentityBook().identity(repo: "chippy"), IdentityBook().identity(repo: "chippy"))
    }

    func testRepeatedAskIsStableEvenAfterOthersArrive() {
        let b = IdentityBook()
        let first = b.identity(repo: "chippy")
        for i in 0..<20 { _ = b.identity(repo: "r\(i)") }
        XCTAssertEqual(b.identity(repo: "chippy"), first)
    }

    func testWorktreesOfOneRepoShareIdentity() { // Shin's #101 comment: key on the repo, worktree is a sub-label
        let b = IdentityBook()
        XCTAssertEqual(b.identity(for: RepoLabel(repo: "govapps", worktree: "fix-53")), b.identity(for: RepoLabel(repo: "govapps", worktree: "fix-51")))
        XCTAssertEqual(b.identity(for: RepoLabel(repo: "govapps")), b.identity(for: RepoLabel(repo: "govapps", worktree: "fix-51")))
    }

    func testCollisionAwareUpToSlotCount() {
        let b = IdentityBook()
        let ids = (0..<SessionIdentity.slotCount).map { b.identity(repo: "repo-\($0)") }
        XCTAssertEqual(Set(ids.map { "\($0.colour)-\($0.shape.rawValue)" }).count, SessionIdentity.slotCount)
    }

    func testTwoRepoNamesWithSameHashStartStillDiffer() {
        var seen: [Int: String] = [:]
        var pair: (String, String)?
        for i in 0..<500 where pair == nil {
            let n = "x\(i)"; let s = Int(IdentityBook.fnv1a(n) % UInt64(SessionIdentity.slotCount))
            if let o = seen[s] { pair = (o, n) } else { seen[s] = n }
        }
        let p = try! XCTUnwrap(pair)
        let b = IdentityBook()
        XCTAssertNotEqual(b.identity(repo: p.0), b.identity(repo: p.1))
    }

    func testShapeAndGlyphAlwaysPresent() {
        let b = IdentityBook()
        XCTAssertEqual(b.identity(repo: "chippy").glyph, "C")
        XCTAssertEqual(b.identity(repo: "-api").glyph, "A")
        XCTAssertEqual(b.identity(repo: "").glyph, "#")
        XCTAssertEqual(b.identity(repo: "ßtool").glyph, "S")   // uppercased first Character, ASCII only
        XCTAssertEqual(b.identity(repo: "élan").glyph, "É")
        XCTAssertTrue(SessionIdentity.Shape.allCases.count >= 3, "colour is never the only cue")
        XCTAssertFalse(b.identity(repo: "chippy").spoken.isEmpty)
    }

    func testPastCapacityEvictsLeastRecentlyUsed() {
        let b = IdentityBook()
        for i in 0..<SessionIdentity.slotCount { _ = b.identity(repo: "r\(i)") }
        XCTAssertEqual(b.count, SessionIdentity.slotCount)
        _ = b.identity(repo: "r0")                       // r0 is now the most recent; r1 is the oldest
        let late = b.identity(repo: "late")
        XCTAssertEqual(b.count, SessionIdentity.slotCount)
        XCTAssertTrue(b.knows("late")); XCTAssertTrue(b.knows("r0")); XCTAssertFalse(b.knows("r1"))
        XCTAssertEqual(b.identity(repo: "late"), late)   // stored, so stable
    }

    func testUnresolvedFallbackIsNotStoredAndResolvedGetsItsSlot() {
        let b = IdentityBook()
        _ = b.identity(for: RepoLabel(repo: "fix-53"), resolved: false)
        XCTAssertFalse(b.knows("fix-53")); XCTAssertEqual(b.count, 0)
        let g = b.identity(for: RepoLabel(repo: "govapps", worktree: "fix-53"), resolved: true)
        XCTAssertTrue(b.knows("govapps")); XCTAssertFalse(b.knows("fix-53")); XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b.identity(repo: "govapps", resolved: false), g) // a stored repo keeps its slot even if asked unresolved
    }

    func testUnresolvedUsesRawHashSlot() {
        let raw = Int(IdentityBook.fnv1a("x") % UInt64(SessionIdentity.slotCount))
        XCTAssertEqual(IdentityBook().identity(repo: "x", resolved: false), SessionIdentity(slot: raw, repo: "x"))
    }

    func testHashIsFixed() { XCTAssertEqual(IdentityBook.fnv1a(""), 0xcbf29ce484222325) }

    func testGlyphSizeHasAnEightPointFloor() { // #213: the 12pt glance mark's letter was about 7pt
        XCTAssertEqual(SessionIdentity.glyphSize(for: 11), 8)
        XCTAssertEqual(SessionIdentity.glyphSize(for: 12), 8)
        XCTAssertEqual(SessionIdentity.glyphSize(for: 14), 14 * 0.58, accuracy: 0.0001)
        XCTAssertEqual(SessionIdentity.glyphSize(for: 22), 22 * 0.58, accuracy: 0.0001)
    }
}
