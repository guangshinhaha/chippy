import XCTest
@testable import ChippyCore

/// Issue #101: one consistent repo (+ worktree) label per row, resolved from git, cached, with a folder-name fallback.
final class RepoIdentityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = scratchURL("chippy-repoid-\(UUID())").resolvingSymlinksInPath()
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

    func testLinkedWorktreeNamedLikeTheRepoStillGetsATag() throws {
        let (_, w) = try linked(main: "orca/chippy", wt: "wt/chippy", name: "chippy2")
        let label = RepoResolver.resolve(cwd: w.path)
        XCTAssertEqual(label, RepoLabel(repo: "chippy", worktree: "wt/chippy"))
        let main = RepoResolver.resolve(cwd: root.appendingPathComponent("orca/chippy").path)
        XCTAssertNil(main.worktree)
    }

    func testChangeNotificationUsesTheLatestCallersFallback() {
        var queued: [() -> Void] = []
        var redraws = 0
        let cache = RepoIdentityCache(resolver: { _ in RepoLabel(repo: "second") }, background: { queued.append($0) }, deliver: { $0() })
        cache.addObserver { redraws += 1 }
        _ = cache.label(cwd: "/w/x", project: "first")  // shown "first"
        _ = cache.label(cwd: "/w/x", project: "second") // same cwd, but path gives the folder name; fb equal both times
        _ = cache.label(cwd: "", project: "")
        queued.removeFirst()()
        XCTAssertEqual(redraws, 1) // resolved "second" differs from what the latest caller saw ("x")
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
        cache.addObserver { redraws += 1 }
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
        cache.addObserver { redraws += 1 }
        _ = cache.label(cwd: "/w/api")
        XCTAssertEqual(redraws, 0)
    }

    func testDefaultCacheResolvesOffTheMainThread() throws {
        let w = try linked(main: "govapps", wt: "fix-9", name: "fix-9").wt
        let done = expectation(description: "resolved on main")
        let cache = RepoIdentityCache()
        cache.addObserver { XCTAssertTrue(Thread.isMainThread); done.fulfill() }
        XCTAssertEqual(cache.label(cwd: w.path).repo, "fix-9") // immediate fallback
        wait(for: [done], timeout: 5)
        XCTAssertEqual(cache.label(cwd: w.path), RepoLabel(repo: "govapps", worktree: "fix-9"))
    }

    func testDeletedLinkedWorktreeKeepsItsTagAndResolveMatchesFallback() throws {
        let m = try dir("chippy"); _ = try dir("chippy/.git")
        let gone = m.appendingPathComponent(".claude/worktrees/wf_gone-1").path // never created
        XCTAssertEqual(RepoResolver.fallback(cwd: gone), RepoLabel(repo: "chippy", worktree: "wf_gone-1"))
        XCTAssertEqual(RepoResolver.resolve(cwd: gone), RepoResolver.fallback(cwd: gone))
        // present folder without its own .git, inside the repo: git can't confirm, the path tag stays
        let bare = try dir("chippy/.claude/worktrees/wf_plain")
        XCTAssertEqual(RepoResolver.resolve(cwd: bare.path), RepoLabel(repo: "chippy", worktree: "wf_plain"))
    }

    func testCacheEvictsOnlyTheOldestAtCapacity() {
        var t = Date(timeIntervalSince1970: 1000)
        let cache = RepoIdentityCache(resolver: { RepoLabel(repo: "r" + $0) }, background: { $0() }, deliver: { $0() }, now: { t })
        for i in 0..<RepoIdentityCache.capacity { _ = cache.label(cwd: "/w/\(i)"); t = t.addingTimeInterval(0.001) }
        XCTAssertEqual(cache.count, RepoIdentityCache.capacity)
        _ = cache.label(cwd: "/w/new")
        XCTAssertEqual(cache.count, RepoIdentityCache.capacity)          // one out, one in (no wipe)
        XCTAssertEqual(cache.label(cwd: "/w/5").repo, "r/w/5")          // a survivor is still cached
    }

    func testCacheEvictsTheLeastRecentlyUsedNotTheFirstInserted() {
        var t = Date(timeIntervalSince1970: 1000)
        let cache = RepoIdentityCache(resolver: { RepoLabel(repo: "r" + $0) }, background: { $0() }, deliver: { $0() }, now: { t })
        for i in 0..<RepoIdentityCache.capacity { _ = cache.label(cwd: "/w/\(i)"); t = t.addingTimeInterval(0.001) }
        _ = cache.label(cwd: "/w/0")                 // touch the first-inserted entry: it is now the most recently used
        _ = cache.label(cwd: "/w/new")               // past capacity
        XCTAssertTrue(cache.isResolved(cwd: "/w/0"), "a folder still in use survives")
        XCTAssertFalse(cache.isResolved(cwd: "/w/1"), "the least recently used one made room")
        XCTAssertEqual(cache.count, RepoIdentityCache.capacity)
    }

    func testLabelsRefreshAfterTheTTLAndOnlyNotifyOnChange() {
        var t = Date(timeIntervalSince1970: 1000)
        var current = RepoLabel(repo: "api")
        var reads = 0, redraws = 0
        let cache = RepoIdentityCache(resolver: { _ in reads += 1; return current }, background: { $0() }, deliver: { $0() }, now: { t })
        cache.addObserver { redraws += 1 }
        _ = cache.label(cwd: "/w/api")                  // first read: same as the fallback, no redraw
        XCTAssertEqual(reads, 1); XCTAssertEqual(redraws, 0)
        t = t.addingTimeInterval(RepoIdentityCache.ttl - 1)
        _ = cache.label(cwd: "/w/api"); XCTAssertEqual(reads, 1) // still fresh
        t = t.addingTimeInterval(2)
        _ = cache.label(cwd: "/w/api"); XCTAssertEqual(reads, 2) // stale: re-read, unchanged
        XCTAssertEqual(redraws, 0)
        current = RepoLabel(repo: "govapps", worktree: "api") // e.g. the folder became a linked worktree
        t = t.addingTimeInterval(RepoIdentityCache.ttl + 1)
        XCTAssertEqual(cache.label(cwd: "/w/api"), RepoLabel(repo: "api")) // old answer served at once
        XCTAssertEqual(redraws, 1)
        XCTAssertEqual(cache.label(cwd: "/w/api"), current)
    }

    func testEveryObserverIsNotified() {
        var a = 0, b = 0
        let cache = RepoIdentityCache(resolver: { _ in RepoLabel(repo: "x") }, background: { $0() }, deliver: { $0() })
        cache.addObserver { a += 1 }; cache.addObserver { b += 1 }
        _ = cache.label(cwd: "/w/y")
        XCTAssertEqual(a, 1); XCTAssertEqual(b, 1)
    }

    // MARK: worktree tag (#209)

    func testWorktreeTagKeepsAShortName() {
        XCTAssertEqual(RepoLabel.worktreeTag("fix"), "fix")
    }

    func testWorktreeTagMiddleTruncatesALongBranchToExactlySixteen() {
        let long = "feature/very-long-branch-name-here"
        XCTAssertEqual(long.count, 34)
        let name33 = String(long.dropLast())
        XCTAssertEqual(name33.count, 33)
        let t = RepoLabel.worktreeTag(name33)
        XCTAssertEqual(t.count, 16)
        XCTAssertTrue(t.contains("…"))
        XCTAssertEqual(t, "feature/…ame-her")
        XCTAssertEqual(RepoLabel.worktreeTag(long).count, 16)
    }

    func testWorktreeTagEmptyStaysEmpty() {
        XCTAssertEqual(RepoLabel.worktreeTag(""), "")
    }

    func testWorktreeTagExactlySixteenIsUnchanged() {
        let s = "abcdefghijklmnop"
        XCTAssertEqual(s.count, 16)
        XCTAssertEqual(RepoLabel.worktreeTag(s), s)
        XCTAssertEqual(RepoLabel.worktreeTag(s + "q").count, 16)
    }

    func testWorktreeTagCountsEmojiAsOneCharacterAndNeverSplitsThem() {
        let family = "👨‍👩‍👧‍👦"
        let s = String(repeating: family, count: 10) + "-fix-🇸🇬-🇸🇬-🇸🇬"
        let t = RepoLabel.worktreeTag(s)
        XCTAssertEqual(t.count, 16)
        XCTAssertTrue(t.contains("…"))
        XCTAssertTrue(t.hasPrefix(String(repeating: family, count: 8)))
        XCTAssertTrue(t.hasSuffix("🇸🇬-🇸🇬"))
        XCTAssertEqual(RepoLabel.worktreeTag("🚀fix"), "🚀fix")
    }

    func testWorktreeTagTinyCapsDoNotCrash() {
        XCTAssertEqual(RepoLabel.worktreeTag("branch", maxChars: 2), "b…")
        XCTAssertEqual(RepoLabel.worktreeTag("branch", maxChars: 1), "…")
        XCTAssertEqual(RepoLabel.worktreeTag("branch", maxChars: 0), "")
        XCTAssertEqual(RepoLabel.worktreeTag("branch", maxChars: -3), "")
        XCTAssertEqual(RepoLabel.worktreeTag("b", maxChars: 1), "b")
    }
}
