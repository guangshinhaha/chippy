import XCTest
@testable import ChippyCore

/// Issue #101: one consistent repo (+ worktree) label per row, resolved from git, cached, with a folder-name fallback.
final class RepoIdentityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chippy-repoid-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func dir(_ path: String) throws -> URL {
        let u = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// A main checkout `<root>/<name>` with `.git/` and a linked worktree whose pointer file lives at `wt`.
    private func linked(main: String, wt: String, name: String) throws -> (main: URL, wt: URL) {
        let m = try dir(main)
        _ = try dir("\(main)/.git/worktrees/\(name)")
        let w = try dir(wt)
        try "gitdir: \(m.path)/.git/worktrees/\(name)\n".write(to: w.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return (m, w)
    }

    func testPlainRepoIsItsFolderWithNoWorktreeTag() throws {
        let r = try dir("govapps"); _ = try dir("govapps/.git"); let sub = try dir("govapps/Sources/App")
        XCTAssertEqual(RepoResolver.resolve(cwd: r.path), RepoLabel(repo: "govapps"))
        XCTAssertEqual(RepoResolver.resolve(cwd: sub.path), RepoLabel(repo: "govapps")) // a subfolder is still the repo
    }

    func testClaudeWorktreeResolvesToItsRepo() throws {
        let (_, w) = try linked(main: "chippy", wt: "chippy/.claude/worktrees/wf_abc-1", name: "wf_abc-1")
        XCTAssertEqual(RepoResolver.resolve(cwd: w.path), RepoLabel(repo: "chippy", worktree: "wf_abc-1"))
    }

    func testOrcaStyleSiblingWorktreeResolvesToTheMainRepo() throws {
        let (_, w) = try linked(main: "govapps", wt: "fix-53", name: "fix-53") // not under .claude/worktrees
        let label = RepoResolver.resolve(cwd: w.path)
        XCTAssertEqual(label, RepoLabel(repo: "govapps", worktree: "fix-53"))
        XCTAssertEqual(label.text, "govapps / fix-53")
        // the old folder-name rule would have said "fix-53" (the bug in the issue's screenshot)
        XCTAssertEqual(RepoResolver.fallback(cwd: w.path).repo, "fix-53")
    }

    func testRelativeGitdirPointerAndBareCommonDir() throws {
        let bare = try dir("shared.git/worktrees/w1")
        let w = try dir("w1")
        try "gitdir: ../shared.git/worktrees/w1".write(to: w.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RepoResolver.resolve(cwd: w.path), RepoLabel(repo: "shared", worktree: "w1"))
        _ = bare
    }

    func testSubmoduleIsItsOwnRepo() throws {
        let s = try dir("super/vendor/lib")
        try "gitdir: ../../.git/modules/lib".write(to: s.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RepoResolver.resolve(cwd: s.path), RepoLabel(repo: "lib"))
    }

    func testNonGitFolderFallsBackToFolderName() throws {
        let d = try dir("scratch/notes")
        XCTAssertEqual(RepoResolver.resolve(cwd: d.path), RepoLabel(repo: "notes"))
        XCTAssertEqual(RepoResolver.resolve(cwd: "/no/such/path/thing"), RepoLabel(repo: "thing"))
        XCTAssertEqual(RepoResolver.resolve(cwd: "", project: "p"), RepoLabel(repo: "p"))
        XCTAssertEqual(RepoResolver.resolve(cwd: ""), RepoLabel(repo: "unknown"))
    }

    func testFallbackMapsClaudeWorktreeWithoutGit() {
        XCTAssertEqual(RepoResolver.fallback(cwd: "/x/chippy/.claude/worktrees/agent-1"), RepoLabel(repo: "chippy", worktree: "agent-1"))
    }

    func testBrokenPointerFileFallsBack() throws {
        let w = try dir("odd")
        try "not a pointer".write(to: w.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RepoResolver.resolve(cwd: w.path), RepoLabel(repo: "odd"))
    }

    // MARK: cache

    func testCacheAnswersAtOnceWithFallbackThenResolvesOnceOffTheCaller() {
        var queued: [() -> Void] = []
        var calls = 0
        var redraws = 0
        let cache = RepoIdentityCache(resolver: { _ in calls += 1; return RepoLabel(repo: "govapps", worktree: "fix-53") },
                                      background: { queued.append($0) }, deliver: { $0() })
        cache.onResolved = { redraws += 1 }
        XCTAssertEqual(cache.label(cwd: "/w/fix-53"), RepoLabel(repo: "fix-53")) // fallback, nothing resolved yet
        XCTAssertEqual(cache.label(cwd: "/w/fix-53"), RepoLabel(repo: "fix-53"))
        XCTAssertEqual(queued.count, 1) // one background read however many asks
        XCTAssertEqual(calls, 0)        // the caller (main thread) never ran the resolver
        queued.removeFirst()()
        XCTAssertEqual(calls, 1); XCTAssertEqual(redraws, 1)
        XCTAssertEqual(cache.label(cwd: "/w/fix-53"), RepoLabel(repo: "govapps", worktree: "fix-53"))
        XCTAssertTrue(queued.isEmpty); XCTAssertEqual(calls, 1)
    }

    func testCacheDoesNotRedrawWhenGitAgreesWithTheFallback() {
        var redraws = 0
        let cache = RepoIdentityCache(resolver: { RepoResolver.fallback(cwd: $0) }, background: { $0() }, deliver: { $0() })
        cache.onResolved = { redraws += 1 }
        _ = cache.label(cwd: "/w/api")
        XCTAssertEqual(redraws, 0)
    }

    func testDefaultCacheResolvesOffTheMainThread() throws {
        let w = try linked(main: "govapps", wt: "fix-9", name: "fix-9").wt
        let done = expectation(description: "resolved on main")
        let cache = RepoIdentityCache()
        cache.onResolved = { XCTAssertTrue(Thread.isMainThread); done.fulfill() }
        XCTAssertEqual(cache.label(cwd: w.path).repo, "fix-9") // immediate fallback
        wait(for: [done], timeout: 5)
        XCTAssertEqual(cache.label(cwd: w.path), RepoLabel(repo: "govapps", worktree: "fix-9"))
    }
}
