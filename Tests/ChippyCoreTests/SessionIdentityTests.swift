import XCTest
@testable import ChippyCore

final class SessionIdentityTests: XCTestCase {
    func testSameRepoSameIdentityAcrossBooks() {
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
        XCTAssertEqual(b.identity(repo: "").glyph, "?")
        XCTAssertTrue(SessionIdentity.Shape.allCases.count >= 3, "colour is never the only cue")
        XCTAssertFalse(b.identity(repo: "chippy").spoken.isEmpty)
    }

    func testPastCapacityStillAnswersDeterministically() {
        let b = IdentityBook()
        for i in 0..<(SessionIdentity.slotCount + 5) { _ = b.identity(repo: "r\(i)") }
        XCTAssertEqual(b.identity(repo: "late"), b.identity(repo: "late"))
    }

    func testHashIsFixed() { XCTAssertEqual(IdentityBook.fnv1a(""), 0xcbf29ce484222325) }
}
