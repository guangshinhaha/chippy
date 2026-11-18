import Darwin
import XCTest
@testable import ChippyCore

/// Issue #101: the waiting list split into NEEDS YOU (act) and FINISHED (FYI).
final class NeedsYouFinishedTests: XCTestCase {
    private func model(identities: RepoIdentityCache = RepoIdentityCache(),
                       tick: @escaping (@escaping () -> Void) -> Void = { $0() }) -> NotchModel {
        NotchModel(always: AlwaysStore(url: nil),
                   log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-101-\(UUID()).jsonl")),
                   identities: identities, tick: tick)
    }
    private func conn() -> Connection {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        return Connection(fd: fds[0])
    }
    private func approval(_ m: NotchModel, _ sid: String, cwd: String = "/w/api", tool: String = "Bash", wait: Int? = nil) {
        let w = wait.map { #","chippy_wait":\#($0)"# } ?? ""
        m.receiveApproval(HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","cwd":"\#(cwd)","tool_name":"\#(tool)","tool_input":{"command":"rm -rf /secret"}\#(w)}"#.utf8))!, conn())
    }
    private func question(_ m: NotchModel, _ sid: String, cwd: String = "/w/qs", count: Int = 2) {
        let qs: [[String: Any]] = (1...count).map { ["question": "Q\($0)?", "header": "H", "multiSelect": false, "options": [["label": "x", "description": ""], ["label": "y", "description": ""]]] }
        let json: [String: Any] = ["session_id": sid, "cwd": cwd, "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": ["questions": qs]]
        m.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: json))!, conn())
    }
    private func stop(_ m: NotchModel, _ sid: String, cwd: String = "/w/done", at: Date = Date(), reply: String? = nil) {
        var o: [String: Any] = ["session_id": sid, "hook_event_name": "Stop", "cwd": cwd]
        if let reply { o["last_assistant_message"] = reply }
        m.apply(HookPayload(json: try! JSONSerialization.data(withJSONObject: o))!, now: at)
    }
    /// A question the hook cannot answer (no options), so it lands as a terminal row.
    private func terminalAsk(_ m: NotchModel, _ sid: String, cwd: String = "/w/term", now: Date = Date()) {
        let o: [String: Any] = ["session_id": sid, "hook_event_name": "PermissionRequest", "cwd": cwd, "tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "q"]]]]
        m.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: o))!, conn(), now: now)
    }

    // MARK: sections and labels

    func testSectionSplitAndRankOrder() {
        let m = model(); let t0 = Date()
        stop(m, "d1", cwd: "/w/d1", at: t0)
        question(m, "q1")
        terminalAsk(m, "t1")
        approval(m, "a1")
        stop(m, "d2", cwd: "/w/d2", at: t0.addingTimeInterval(5))
        let l = m.waitingLayout
        XCTAssertEqual(l.needs.map(\.kind), [.approval, .question, .terminal]) // #93: approvals, questions, then terminal rows
        XCTAssertTrue(l.needs.allSatisfy(\.needsYou))
        XCTAssertEqual(l.finished.map(\.repo), ["d2", "d1"])
        XCTAssertTrue(l.finished.allSatisfy { !$0.needsYou })
    }

    func testVerbLedLabelsCarryNoContent() {
        let m = model()
        approval(m, "a", tool: "Bash")
        question(m, "q", count: 2)
        question(m, "q1", cwd: "/w/one", count: 1)
        terminalAsk(m, "t")
        let labels = Dictionary(uniqueKeysWithValues: m.waitingItems.map { ($0.repo, $0.label) })
        XCTAssertEqual(labels["api"], "Approve Bash?")
        XCTAssertEqual(labels["qs"], "Answer 2 questions")
        XCTAssertEqual(labels["one"], "Answer 1 question")
        XCTAssertEqual(labels["term"], "Asked in terminal")
        for item in m.waitingItems { XCTAssertFalse("\(item)".contains("secret") || "\(item)".contains("Q1?")) }
    }

    func testFinishedAsksYouIsATagAndNeverJoinsNeedsYou() {
        let m = model()
        stop(m, "d", reply: "Done with the migration.\n\nShould I also drop the old column?")
        stop(m, "e", cwd: "/w/other", reply: "All good.")
        XCTAssertTrue(m.waitingLayout.needs.isEmpty)
        XCTAssertNil(m.badge)
        XCTAssertTrue(m.badgeDot)
        let byRepo = Dictionary(uniqueKeysWithValues: m.waitingItems.map { ($0.repo, $0) })
        XCTAssertTrue(byRepo["done"]!.asksYou); XCTAssertEqual(byRepo["done"]!.label, "Asks you")
        XCTAssertFalse(byRepo["other"]!.asksYou)
    }

    // MARK: cap and sizing

    private func rows(needs: Int, finished: Int) -> [WaitingItem] {
        let n = (0..<needs).map { WaitingItem(target: .pending("n\($0)"), kind: .approval, repo: "r\($0)", at: Date()) }
        let f = (0..<finished).map { WaitingItem(target: .done("f\($0)"), kind: .done, repo: "g\($0)", at: Date()) }
        return n + f
    }

    func testMatrixZeroOneFiveNeedsByZeroThreeSixFinished() {
        for needs in [0, 1, 5] {
            for finished in [0, 3, 6] {
                let l = WaitingList.layout(rows(needs: needs, finished: finished))
                XCTAssertEqual(l.needs.count, needs)
                XCTAssertEqual(l.finished.count, min(3, finished), "needs \(needs) finished \(finished)")
                XCTAssertEqual(l.hiddenFinished, finished - min(3, finished))
                XCTAssertEqual(l.totalFinished, finished)
                XCTAssertFalse(l.needsScrolls, "needs \(needs) finished \(finished)") // all of these fit under the cap
                XCTAssertEqual(l.selectable.count, needs + min(3, finished))
            }
        }
    }

    func testFinishedShrinksFirstThenNeedsScrolls() {
        // 8 needs rows leave no room even for the FINISHED header and "+N more": FINISHED is gone first, then NEEDS YOU scrolls.
        let tight = WaitingList.layout(rows(needs: 8, finished: 6))
        XCTAssertEqual(tight.needs.count, 8)                // NEEDS YOU is never cut
        XCTAssertEqual(tight.finished.count, 0)
        XCTAssertEqual(tight.hiddenFinished, 6)
        XCTAssertTrue(tight.needsScrolls)
        // 5 needs + 6 finished fit with the full 3 finished rows; 6 needs force FINISHED down first.
        XCTAssertEqual(WaitingList.layout(rows(needs: 6, finished: 6)).finished.count, 1)
        // Many needs rows: they scroll in a fixed height, and the whole thing stays under the cap.
        let many = WaitingList.layout(rows(needs: 12, finished: 6))
        XCTAssertTrue(many.needsScrolls)
        XCTAssertEqual(many.needs.count, 12)
        XCTAssertEqual(many.finished.count, 0)
        let total = WaitingList.sectionHeaderHeight + many.needsHeight + WaitingList.sectionGap + WaitingList.sectionHeaderHeight + WaitingList.moreRowHeight + WaitingList.chrome
        XCTAssertLessThanOrEqual(total, NotchMetrics.maxExpandedHeight)
        let onlyNeeds = WaitingList.layout(rows(needs: 12, finished: 0))
        XCTAssertTrue(onlyNeeds.needsScrolls)
        XCTAssertLessThanOrEqual(WaitingList.sectionHeaderHeight + onlyNeeds.needsHeight + WaitingList.chrome, NotchMetrics.maxExpandedHeight)
    }

    func testFinishedRowsGroupedByRepoNewestGroupFirst() {
        let t = Date()
        func f(_ id: String, _ repo: String, _ age: Double) -> WaitingItem { WaitingItem(target: .done(id), kind: .done, repo: repo, at: t.addingTimeInterval(-age)) }
        // already newest first, as WaitingList.items gives them
        let l = WaitingList.layout([f("1", "govapps", 1), f("2", "factory", 2), f("3", "govapps", 3)])
        XCTAssertEqual(l.finished.map(\.target), [.done("1"), .done("3"), .done("2")])
    }

    // MARK: keys and selection

    func testArrowKeysWalkOneFlatOrderAndMoreIsNotSelectable() {
        let m = model(); let t0 = Date()
        approval(m, "a"); question(m, "q")
        for i in 0..<5 { stop(m, "d\(i)", cwd: "/w/d\(i)", at: t0.addingTimeInterval(Double(i))) }
        m.openList()
        XCTAssertEqual(m.waitingLayout.hiddenFinished, 2)
        var walked: [WaitingTarget] = [m.listSelection!]
        for _ in 0..<12 { m.moveSelection(1); if let s = m.listSelection, walked.last != s { walked.append(s) } }
        XCTAssertEqual(walked.count, 5) // 2 needs + 3 visible finished, then clamped: the 2 hidden are never reached
        XCTAssertEqual(m.listSelection, .done("d2")) // newest three are d4, d3, d2; grouped order keeps recency
        XCTAssertTrue(walked.prefix(2).allSatisfy { if case .pending = $0 { return true } else { return false } })
        // a selected row that drops out of the visible set (cleared) reconciles to a valid row
        m.dismissDone("d2")
        XCTAssertTrue(m.waitingLayout.selectable.contains { $0.target == m.listSelection })
    }

    func testClearAllMovesFinishedToRecentAndKeepsNeedsYou() {
        let m = model(); let t0 = Date()
        approval(m, "a")
        for i in 0..<4 { stop(m, "d\(i)", cwd: "/w/d\(i)", at: t0.addingTimeInterval(Double(i))) }
        m.openList()
        m.dismissDone(nil)
        XCTAssertTrue(m.doneItems.isEmpty)
        XCTAssertEqual(m.recent.items.count, 4)
        XCTAssertEqual(m.pending.count, 1)
        XCTAssertEqual(m.waitingLayout.totalFinished, 0)
        XCTAssertTrue(m.listOpen) // the list stays up for the approval
    }

    func testTimeoutKeepsSelectionOnTheTerminalRowItBecame() {
        let m = model(); let t0 = Date()
        stop(m, "d", at: t0)
        approval(m, "a", wait: 20)
        approval(m, "b", cwd: "/w/b", wait: 120)
        m.openList()
        XCTAssertEqual(m.listSelection, m.waitingLayout.needs.first?.target)
        let first = m.pending[0].id
        XCTAssertEqual(m.listSelection, .pending(first))
        m.sweep(now: t0.addingTimeInterval(21)) // "a" times out and becomes a terminal row (new id)
        XCTAssertEqual(m.terminalItems.map(\.sessionId), ["a"])
        XCTAssertEqual(m.listSelection, .terminal("a")) // follows it, does not jump to the top
        XCTAssertTrue(m.waitingLayout.selectable.contains { $0.target == .terminal("a") })
    }

    // MARK: terminal rows

    func testHandledClearsTheTerminalRowWithoutRecent() {
        let m = model()
        terminalAsk(m, "t")
        m.dismissTerminal("t")
        XCTAssertTrue(m.terminalItems.isEmpty)
        XCTAssertTrue(m.recent.items.isEmpty)
    }

    func testTerminalRowOutlivesFinishedChipsAndExpiresAfterThirtyMinutes() {
        let m = model(); let t0 = Date()
        stop(m, "d", at: t0)
        terminalAsk(m, "t", now: t0)
        XCTAssertEqual(m.terminalItems.count, 1)
        m.sweep(now: t0.addingTimeInterval(NotchModel.doneSeconds + 5))
        XCTAssertTrue(m.doneItems.isEmpty)                 // finished: 10 min
        XCTAssertEqual(m.terminalItems.count, 1)           // needs-you: still there
        m.sweep(now: t0.addingTimeInterval(NotchModel.terminalSeconds + 5))
        XCTAssertTrue(m.terminalItems.isEmpty)
    }

    // MARK: badge

    func testBadgeCountsNeedsYouOnlyAndDotWhenOnlyFinished() {
        let m = model()
        stop(m, "d")
        XCTAssertNil(m.badge); XCTAssertTrue(m.badgeDot)
        terminalAsk(m, "t")
        XCTAssertEqual(m.badge, "1"); XCTAssertFalse(m.badgeDot)
        m.dismissTerminal("t"); m.dismissDone(nil)
        XCTAssertNil(m.badge); XCTAssertFalse(m.badgeDot)
    }

    func testTerminalOnlyBadgeIsNeedsYouStyleAndNeverADot() {
        let m = model()
        terminalAsk(m, "t")
        XCTAssertEqual(m.badge, "1")
        XCTAssertTrue(m.badgeNeedsYou)          // pulses like a folded approval
        XCTAssertNil(m.foldedDeadline)          // no hook left to time out: pulse, no ring
        XCTAssertFalse(m.badgeDot)
        m.dismissTerminal("t")
        XCTAssertFalse(m.badgeNeedsYou)
    }

    func testFinishedOnlyBadgeIsDotNotNeedsYou() {
        let m = model()
        stop(m, "d")
        XCTAssertTrue(m.badgeDot); XCTAssertFalse(m.badgeNeedsYou)
    }

    func testNoDotWhileAnUnfoldedApprovalIsPending() {
        let m = model()
        stop(m, "d")
        approval(m, "a")
        XCTAssertFalse(m.folded)
        XCTAssertNil(m.badge)
        XCTAssertFalse(m.badgeDot)
        XCTAssertFalse(m.badgeNeedsYou)
    }

    // MARK: label cache wiring

    func testResolvedBurstRefreshesOncePerTick() {
        var queued: [() -> Void] = []
        var jobs: [() -> Void] = []
        let cache = RepoIdentityCache(resolver: { RepoLabel(repo: "r-" + ($0 as NSString).lastPathComponent) },
                                      background: { jobs.append($0) }, deliver: { $0() })
        let m = model(identities: cache, tick: { queued.append($0) })
        for i in 1...5 { stop(m, "s\(i)", cwd: "/w/p\(i)") }
        var published = 0
        let c = m.$waitingItems.dropFirst().sink { _ in published += 1 }
        jobs.forEach { $0() }                      // five resolutions in one burst
        XCTAssertEqual(queued.count, 1)            // one scheduled refresh, not five
        queued.removeFirst()()
        XCTAssertEqual(published, 1)
        XCTAssertEqual(m.waitingItems.first?.repo.hasPrefix("r-"), true)
        c.cancel()
    }

    func testSharedCacheKeepsEveryModelsObserver() {
        var jobs: [() -> Void] = []
        let cache = RepoIdentityCache(resolver: { _ in RepoLabel(repo: "resolved") }, background: { jobs.append($0) }, deliver: { $0() })
        let a = model(identities: cache), b = model(identities: cache)
        stop(a, "x", cwd: "/w/one"); stop(b, "y", cwd: "/w/one")
        jobs.forEach { $0() }
        XCTAssertEqual(a.waitingItems.first?.repo, "resolved")
        XCTAssertEqual(b.waitingItems.first?.repo, "resolved") // creating b did not unseat a
    }

    func testChipsCardsAndRecentUseTheRowLabel() {
        let cache = RepoIdentityCache(resolver: { _ in RepoLabel(repo: "govapps", worktree: "fix-53") }, background: { $0() }, deliver: { $0() })
        let m = model(identities: cache)
        stop(m, "d", cwd: "/work/fix-53")
        terminalAsk(m, "t", cwd: "/work/fix-53")
        let want = "govapps / fix-53"
        let row = m.waitingItems.first { $0.target == .done("d") }!
        XCTAssertEqual(RepoLabel(repo: row.repo, worktree: row.worktree).text, want)
        let d = m.doneItems[0], t = m.terminalItems[0]
        XCTAssertEqual(m.repoLabel(cwd: d.cwd, project: d.project).text, want)
        XCTAssertEqual(t.glance(repo: m.repoLabel(cwd: t.cwd, project: t.project).text), "\(want) · asked in terminal")
        XCTAssertEqual(d.glance(showReply: false, repo: want), "\(want) · finished")
        XCTAssertTrue(d.identityLine(repo: want).hasPrefix(want))
        m.dismissDone("d")
        let r = m.recent.items[0]
        XCTAssertEqual(m.repoLabel(cwd: r.cwd, project: r.project).text, want)
    }

    // MARK: height budget

    func testNeedsRegionNeverPassesTheCapAndScrollsInstead() {
        for n in [1, 5, 9, 10, 20, 60] {
            let rows = (0..<n).map { WaitingItem(target: .pending("n\($0)"), kind: .approval, repo: "r", at: Date()) }
            let l = WaitingList.layout(rows)
            XCTAssertLessThanOrEqual(WaitingList.sectionHeaderHeight + l.needsHeight + WaitingList.chrome, NotchMetrics.maxExpandedHeight)
        }
        // an absurdly small budget still clamps
        let rows = (0..<5).map { WaitingItem(target: .pending("n\($0)"), kind: .approval, repo: "r", at: Date()) }
        XCTAssertLessThanOrEqual(WaitingList.layout(rows, budget: 30).needsHeight, 30)
    }

    func testChromeIsBuiltFromTheSharedViewConstants() {
        XCTAssertEqual(WaitingList.chrome, NotchMetrics.tallestCamera + NotchMetrics.cameraInset + 2 * NotchMetrics.cardSpacing
            + NotchMetrics.cardHeaderHeight + WaitingList.sectionGap + NotchMetrics.keyHintHeight + NotchMetrics.shapePadding)
    }

    // MARK: consistent repo + worktree labels

    func testRowsUseTheResolvedRepoAndWorktreeTag() {
        let cache = RepoIdentityCache(resolver: { cwd in
            cwd.hasSuffix("fix-53") ? RepoLabel(repo: "govapps", worktree: "fix-53") : RepoLabel(repo: (cwd as NSString).lastPathComponent)
        }, background: { $0() }, deliver: { $0() })
        let m = model(identities: cache)
        stop(m, "s1", cwd: "/work/govapps")
        stop(m, "s2", cwd: "/work/fix-53") // first sight: fallback; the cache resolves synchronously here
        stop(m, "s3", cwd: "/work/fix-53")
        let byId = Dictionary(uniqueKeysWithValues: m.waitingItems.map { ($0.target, $0) })
        XCTAssertEqual(byId[.done("s2")]?.repo, "govapps")
        XCTAssertEqual(byId[.done("s2")]?.worktree, "fix-53")
        XCTAssertNil(byId[.done("s1")]?.worktree)
        XCTAssertEqual(byId[.done("s1")]?.repo, byId[.done("s3")]?.repo) // same level: both are the repo
    }
}
