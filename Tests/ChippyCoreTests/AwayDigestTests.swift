import XCTest
@testable import ChippyCore

final class AwayDigestTests: XCTestCase {
    let t0 = Date().addingTimeInterval(-1000) // a terminal ask is stamped with the real clock (createdAt)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: away threshold

    func testIdleBelowThresholdIsNotAway() {
        var t = AwayTracker(threshold: 300)
        XCTAssertNil(t.observe(now: at(0), locked: false, idle: 299))
        XCTAssertFalse(t.isAway)
    }

    func testIdleReturnReportsStartOnce() {
        var t = AwayTracker(threshold: 300)
        XCTAssertNil(t.observe(now: at(0), locked: false, idle: 300))
        XCTAssertTrue(t.isAway)
        XCTAssertNil(t.observe(now: at(100), locked: false, idle: 400)) // still away: nothing yet
        XCTAssertEqual(t.observe(now: at(200), locked: false, idle: 1), at(-300)) // back: start = first idle reading minus idle
        XCTAssertNil(t.observe(now: at(201), locked: false, idle: 2)) // once per away period
        XCTAssertFalse(t.isAway)
    }

    func testLongLockReports() {
        var t = AwayTracker(threshold: 300)
        XCTAssertNil(t.observe(now: at(0), locked: true, idle: 0))
        XCTAssertNil(t.observe(now: at(400), locked: true, idle: 400))
        XCTAssertEqual(t.observe(now: at(500), locked: false, idle: 0), at(0))
    }

    func testShortLockIsNotAway() {
        var t = AwayTracker(threshold: 300)
        XCTAssertNil(t.observe(now: at(0), locked: true, idle: 0))
        XCTAssertNil(t.observe(now: at(299), locked: false, idle: 0))
        XCTAssertFalse(t.isAway)
    }

    func testSecondAwayPeriodReportsAgain() {
        var t = AwayTracker(threshold: 300)
        _ = t.observe(now: at(0), locked: true, idle: 0)
        XCTAssertNotNil(t.observe(now: at(600), locked: false, idle: 0))
        _ = t.observe(now: at(700), locked: true, idle: 0)
        XCTAssertEqual(t.observe(now: at(1100), locked: false, idle: 0), at(700))
    }

    // MARK: ordering, dedupe, caps

    private func done(_ sid: String, _ cwd: String, _ s: TimeInterval, reply: String? = "SECRET-REPLY") -> DoneItem {
        DoneItem(sessionId: sid, project: cwd, branch: nil, files: 0, added: 0, removed: 0, reply: reply, prompt: "SECRET-PROMPT", at: at(s), cwd: cwd)
    }
    private func term(_ sid: String, _ s: TimeInterval) -> TerminalItem { TerminalItem(sessionId: sid, project: sid, at: at(s), tool: "Bash", cwd: sid) }

    func testOnlyItemsFromTheAwayPeriodCount() {
        let r = AwayDigest.build(since: at(100), terminal: [term("new", 100)],
                                 done: [done("d-old", "d-old", 50), done("d-new", "d-new", 150)],
                                 recent: [RecentItem(sessionId: "r-old", project: "r-old", at: at(10)), RecentItem(sessionId: "r-new", project: "r-new", at: at(120))])
        XCTAssertEqual(Set(r.rows.map(\.sessionId)), ["new", "d-new", "r-new"])
    }

    func testTerminalAskRaisedBeforeAwayIsNotARow() {
        let r = AwayDigest.build(since: at(100), terminal: [term("old", 10)], done: [done("d", "d", 150)], recent: [])
        XCTAssertEqual(r.rows.map(\.sessionId), ["d"])
        XCTAssertTrue(AwayDigest.build(since: at(100), terminal: [term("old", 10)], done: [], recent: []).isEmpty)
    }

    func testItemsAfterTheAwayEndAreExcluded() {
        let r = AwayDigest.build(since: at(100), until: at(200), terminal: [term("late", 250)], done: [done("in", "in", 150), done("late2", "late2", 300)], recent: [])
        XCTAssertEqual(r.rows.map(\.sessionId), ["in"])
    }

    // MARK: tracker: back-dating and sleep

    func testLockAfterIdleLeadInIsBackDated() {
        var t = AwayTracker(threshold: 300)
        XCTAssertNil(t.observe(now: at(0), locked: true, idle: 240)) // idle 4 min, then lock
        XCTAssertEqual(t.observe(now: at(400), locked: false, idle: 0), at(-240))
    }

    func testSleepGapIsAnAwayPeriodFromThePreviousPoll() {
        var t = AwayTracker(threshold: 300)
        XCTAssertNil(t.observe(now: at(0), locked: false, idle: 0))
        XCTAssertNil(t.observe(now: at(3600), locked: false, idle: 3600)) // slept an hour, idle clock agrees
        XCTAssertEqual(t.observe(now: at(3605), locked: false, idle: 1), at(0))
    }

    func testThrottledTimerWithActiveUserIsNotAway() {
        var t = AwayTracker(threshold: 300)
        XCTAssertNil(t.observe(now: at(0), locked: false, idle: 0))
        XCTAssertNil(t.observe(now: at(900), locked: false, idle: 2)) // timer starved, user typing
        XCTAssertFalse(t.isAway)
    }

    func testSleepWakeToLockScreenStaysAway() {
        var t = AwayTracker(threshold: 300)
        _ = t.observe(now: at(0), locked: false, idle: 0)
        XCTAssertNil(t.observe(now: at(3600), locked: true, idle: 0))
        XCTAssertEqual(t.observe(now: at(3700), locked: false, idle: 0), at(0))
    }

    func testOrderNeedsYouOldestFirstThenFinishedNewestFirst() {
        let r = AwayDigest.build(since: at(0), terminal: [term("t2", 20), term("t1", 10)],
                                 done: [done("a", "a", 30), done("b", "b", 50)],
                                 recent: [RecentItem(sessionId: "c", project: "c", at: at(40))])
        XCTAssertEqual(r.rows.map(\.sessionId), ["t1", "t2", "b", "c", "a"])
        XCTAssertEqual(r.rows.map(\.status), [.needsYou, .needsYou, .finished, .finished, .finished])
    }

    func testDedupeOneRowPerSessionNeedsYouWins() {
        let r = AwayDigest.build(since: at(0), terminal: [term("s", 10)], done: [done("s", "s", 20), done("x", "x", 5)],
                                 recent: [RecentItem(sessionId: "x", project: "x", at: at(6)), RecentItem(sessionId: "s", project: "s", at: at(7))])
        XCTAssertEqual(r.rows.map(\.sessionId), ["s", "x"])
        XCTAssertEqual(r.rows[0].status, .needsYou)
        XCTAssertNotNil(r.rows[1].target) // the live chip beats the Recent entry
    }

    func testAsksYouIsATagAndCapHidesTheRest() {
        let d = (0..<8).map { done("s\($0)", "s\($0)", Double($0)) }
        let r = AwayDigest.build(since: at(0), terminal: [], done: d, recent: [])
        XCTAssertEqual(r.rows.count, AwayDigest.maxRows)
        XCTAssertEqual(r.hidden, 3); XCTAssertEqual(r.total, 8)
        XCTAssertEqual(r.rows.first?.sessionId, "s7")
        let q = AwayDigest.build(since: at(0), terminal: [], done: [done("q", "q", 1, reply: "Done.\n\nShall I deploy it?")], recent: [])
        XCTAssertEqual(q.rows.first?.status, .asksYou)
    }

    func testRowsCarryNoContent() {
        let r = AwayDigest.build(since: at(0), terminal: [], done: [done("a", "/x/repo", 1)], recent: [])
        XCTAssertFalse("\(r)".contains("SECRET"))
    }

    func testRepoLabelAndResolvedFlow() {
        let r = AwayDigest.build(since: at(0), terminal: [], done: [done("a", "/x/wt", 1)], recent: [],
                                 label: { _, _ in RepoLabel(repo: "govapps", worktree: "wt") }, resolved: { _ in false })
        XCTAssertEqual(r.rows[0].repo, "govapps"); XCTAssertEqual(r.rows[0].worktree, "wt"); XCTAssertFalse(r.rows[0].resolved)
    }

    // MARK: model

    private func model(locked: @escaping () -> Bool = { false }, idle: @escaping () -> TimeInterval = { 0 }) -> NotchModel {
        let m = NotchModel(always: AlwaysStore(url: nil),
                           log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")))
        m.awaySignal = { (locked(), idle()) }
        return m
    }
    private func stop(_ m: NotchModel, _ sid: String, cwd: String = "/x/p", at: Date) {
        m.apply(HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"Stop","cwd":"\#(cwd)","last_assistant_message":"SECRET"}"#.utf8))!, now: at)
    }

    func testReturnWithFinishedWorkOffersDotNotAPopOrSound() {
        var locked = true
        var sounds = 0
        let m = model(locked: { locked })
        m.onSound = { _, _, _, _ in sounds += 1 }
        m.sweep(now: at(0))
        stop(m, "a", at: at(100))
        let soundsAfterStop = sounds
        let densityBefore = m.density
        m.sweep(now: at(400))
        locked = false
        m.sweep(now: at(500))
        XCTAssertNotNil(m.awayDigest); XCTAssertEqual(m.awayDigest?.rows.map(\.sessionId), ["a"])
        XCTAssertTrue(m.badgeDot)
        XCTAssertFalse(m.restOpen); XCTAssertFalse(m.doneOpen); XCTAssertFalse(m.listOpen) // never pops by itself
        XCTAssertEqual(m.density, densityBefore)
        XCTAssertEqual(sounds, soundsAfterStop) // no sound
    }

    func testNothingToReportMeansNoDigest() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); locked = false; m.sweep(now: at(400))
        XCTAssertNil(m.awayDigest); XCTAssertNil(m.awaySince); XCTAssertFalse(m.badgeDot)
    }

    func testWorkFinishedBeforeAwayIsNotInTheDigest() {
        var locked = false
        let m = model(locked: { locked })
        stop(m, "before", at: at(-100))
        m.sweep(now: at(0)); locked = true; m.sweep(now: at(10)); locked = false; m.sweep(now: at(400))
        XCTAssertNil(m.awayDigest)
    }

    func testIdleAwayCountsFromWhenInputStopped() {
        var idle: TimeInterval = 0
        let m = model(idle: { idle })
        stop(m, "a", at: at(-10)) // finished while the user was still typing
        stop(m, "b", at: at(-250)) // finished before the 5 min of idleness began? idle start = now - idle
        idle = 600; m.sweep(now: at(0)) // away since -600
        idle = 1; m.sweep(now: at(10))
        XCTAssertEqual(m.awaySince, at(-600))
        XCTAssertEqual(Set(m.awayDigest?.rows.map(\.sessionId) ?? []), ["a", "b"])
    }

    func testDismissMovesFinishedToRecentAndClears() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        m.dismissAwayDigest(now: at(401))
        XCTAssertNil(m.awayDigest); XCTAssertNil(m.awaySince); XCTAssertFalse(m.badgeDot)
        XCTAssertTrue(m.doneItems.isEmpty)
        XCTAssertEqual(m.recent.items.map(\.sessionId), ["a"])
    }

    func testClosingThePanelAfterOpeningMarksSeenAndKeepsChips() {
        var locked = true
        var t = at(400)
        let m = model(locked: { locked })
        m.dwellClock = { t }
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        m.openBadge() // the dot's tap
        XCTAssertTrue(m.restOpen); XCTAssertNotNil(m.awayDigest)
        XCTAssertEqual(m.headerTitle, "While you were away")
        t = at(402) // read for a couple of seconds
        m.closeDetail()
        XCTAssertNil(m.awayDigest); XCTAssertEqual(m.doneItems.count, 1) // seen, not dismissed
    }

    func testDotToggleClosesAndMarksSeen() {
        var locked = true
        var t = at(400)
        let m = model(locked: { locked })
        m.dwellClock = { t }
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        m.openBadge(); XCTAssertTrue(m.restOpen)
        t = at(402)
        m.openBadge()
        XCTAssertFalse(m.restOpen); XCTAssertNil(m.awaySince)
    }

    func testRowActivationDoesNotMarkSeen() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        m.openBadge()
        m.activate(.done("a"))
        XCTAssertFalse(m.restOpen)
        XCTAssertNotNil(m.awaySince); XCTAssertNotNil(m.awayDigest)
        XCTAssertTrue(m.badgeDot || m.doneOpen)
    }

    func testApprovalFoldingThePanelDoesNotMarkSeen() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        m.openBadge(); XCTAssertTrue(m.restOpen)
        m.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: ["session_id": "p", "hook_event_name": "PermissionRequest",
            "cwd": "/x/p", "tool_name": "Bash", "tool_input": ["command": "ls"]]))!, Connection.detached(), now: at(410))
        XCTAssertFalse(m.restOpen)
        XCTAssertNotNil(m.awaySince); XCTAssertNotNil(m.awayDigest)
    }

    func testDismissMovesAllFinishedIncludingHiddenOnes() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0))
        for i in 0..<8 { stop(m, "s\(i)", cwd: "/x/p\(i)", at: at(50 + Double(i))) }
        locked = false; m.sweep(now: at(400))
        XCTAssertEqual(m.awayDigest?.total, 8); XCTAssertEqual(m.awayDigest?.rows.count, 8) // every chip is a row now
        m.dismissAwayDigest(now: at(401))
        XCTAssertTrue(m.doneItems.isEmpty)
        XCTAssertFalse(m.recent.items.isEmpty) // Recent keeps its own cap; the point is no chip is left behind
        XCTAssertNil(m.awayDigest)
    }

    func testIdleThenLockCountsFinishDuringLeadIn() {
        var locked = false
        var idle: TimeInterval = 240
        let m = model(locked: { locked }, idle: { idle })
        stop(m, "lead", at: at(-100)) // finished while idle (idle began at -240)
        locked = true; m.sweep(now: at(0))
        locked = false; idle = 1; m.sweep(now: at(400))
        XCTAssertEqual(m.awaySince, at(-240))
        XCTAssertEqual(m.awayDigest?.rows.map(\.sessionId), ["lead"])
    }

    func testSleepGapOnModelOffersDigest() {
        let m = model()
        var idle: TimeInterval = 0
        m.awaySignal = { (false, idle) }
        m.sweep(now: at(0))
        stop(m, "a", at: at(3400))
        idle = 3600; m.sweep(now: at(3600))
        idle = 1; m.sweep(now: at(3605))
        XCTAssertEqual(m.awaySince, at(0))
        XCTAssertEqual(m.awayDigest?.rows.map(\.sessionId), ["a"])
    }

    func testAwaySignalPolledAtMostEveryFiveSeconds() {
        var polls = 0
        let m = model()
        m.awaySignal = { polls += 1; return (false, 0) }
        for i in 0..<20 { m.sweep(now: at(Double(i) * 0.5)) } // 10s of 0.5s sweeps
        XCTAssertEqual(polls, 2)
    }

    func testDotLabelSaysAwayEvenWithFinishedChips() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        XCTAssertFalse(m.doneItems.isEmpty)
        XCTAssertEqual(m.badgeDotLabel, "While you were away: 1 update")
    }

    func testOpenDigestIgnoredWhileAnApprovalWaits() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        m.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: ["session_id": "p", "hook_event_name": "PermissionRequest",
            "cwd": "/x/p", "tool_name": "Bash", "tool_input": ["command": "ls"]]))!, Connection.detached(), now: at(410))
        m.openDigest()
        XCTAssertFalse(m.restOpen) // the approval card owns the panel
    }

    func testOncePerAwayPeriodAndNewPeriodReoffers() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        m.dismissAwayDigest(now: at(401))
        m.sweep(now: at(402)); m.sweep(now: at(403))
        XCTAssertNil(m.awayDigest) // not offered again without a new away period
        locked = true; m.sweep(now: at(500)); stop(m, "b", at: at(600)); locked = false; m.sweep(now: at(900))
        XCTAssertEqual(m.awayDigest?.rows.map(\.sessionId), ["b"])
    }

    func testTerminalAskDuringAwayIsNeedsYouRow() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0))
        let multi: [String: Any] = ["questions": [["question": "SECRET Q?", "header": "h", "multiSelect": true,
            "options": [["label": "A, x", "description": "a"], ["label": "B", "description": "b"]]]]]
        m.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: ["session_id": "q", "hook_event_name": "PermissionRequest",
            "cwd": "/x/p", "tool_name": "AskUserQuestion", "tool_input": multi]))!, Connection.detached(), now: at(60))
        locked = false; m.sweep(now: at(1200)) // the ask is stamped with the real clock (about at(1000)), inside the window
        XCTAssertEqual(m.awayDigest?.rows.first?.status, .needsYou)
    }

    func testFinishAfterReturnIsNotFoldedIn() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        stop(m, "later", cwd: "/x/q", at: at(450)); m.sweep(now: at(460))
        XCTAssertEqual(m.awayDigest?.rows.map(\.sessionId), ["a"])
        XCTAssertEqual(m.awayEnd, at(400))
    }

    func testAwayStateClearsWhenDigestEmptiesOnItsOwn() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        m.dismissDone("a", now: at(401))
        XCTAssertNotNil(m.awayDigest) // still in Recent
        m.sweep(now: at(401 + 2400)) // Recent's TTL passes: nothing left to report
        XCTAssertNil(m.awayDigest); XCTAssertNil(m.awaySince); XCTAssertNil(m.awayEnd)
    }

    func testDismissLeavesAskingChipInFinished() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0))
        m.apply(HookPayload(json: Data(#"{"session_id":"q","hook_event_name":"Stop","cwd":"/x/p","last_assistant_message":"Done.\n\nShall I deploy it?"}"#.utf8))!, now: at(50))
        stop(m, "f", cwd: "/x/f", at: at(60))
        locked = false; m.sweep(now: at(400))
        m.dismissAwayDigest(now: at(401))
        XCTAssertEqual(m.doneItems.map(\.sessionId), ["q"])
        XCTAssertEqual(m.recent.items.map(\.sessionId), ["f"])
    }

    func testClosingWhileJumpedToDoneCardDoesNotMarkSeen() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        m.openBadge(); m.activate(.done("a"))
        m.closeDetail()
        XCTAssertNotNil(m.awaySince)
    }

    func testSecondAwayPeriodMergesIntoUnseenDigest() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0)); stop(m, "night", at: at(50)); locked = false; m.sweep(now: at(400)) // overnight, unseen
        locked = true; m.sweep(now: at(1000)) // lunch lock: the window reopens
        XCTAssertNil(m.awayEnd)
        stop(m, "lunch", cwd: "/x/q", at: at(1100))
        locked = false; m.sweep(now: at(1500))
        XCTAssertEqual(m.awaySince, at(0)); XCTAssertEqual(m.awayEnd, at(1500))
        XCTAssertEqual(Set(m.awayDigest?.rows.map(\.sessionId) ?? []), ["night", "lunch"])
    }

    func testEveryCoveredChipIsARow() {
        var locked = true
        let m = model(locked: { locked })
        m.sweep(now: at(0))
        for i in 0..<8 { stop(m, "s\(i)", cwd: "/x/p\(i)", at: at(10 + Double(i))) }
        locked = false; m.sweep(now: at(400))
        XCTAssertEqual(m.awayDigest?.rows.count, 8); XCTAssertEqual(m.awayDigest?.hidden, 0)
    }

    // MARK: #120 leftovers

    /// An away return with one finished chip, panel opened on the digest at `opened`; the model clock reads `now`.
    private func openedDigest(_ now: @escaping () -> Date) -> NotchModel {
        var locked = true
        let m = model(locked: { locked })
        m.dwellClock = now
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        return m
    }

    func testClosingTheDigestWithinASecondDoesNotMarkItSeen() {
        var t = at(500)
        let m = openedDigest { t }
        m.openBadge()
        t = at(500.5)
        m.closeDetail()
        XCTAssertFalse(m.restOpen)
        XCTAssertNotNil(m.awayDigest, "closed before it could be read: the dot stays")
        XCTAssertTrue(m.badgeDot)
    }

    func testClosingTheDigestAfterASecondMarksItSeen() {
        var t = at(500)
        let m = openedDigest { t }
        m.openBadge()
        t = at(501)
        m.closeDetail()
        XCTAssertNil(m.awayDigest); XCTAssertNil(m.awaySince)
    }

    func testTheDwellCountsFromWhenThePanelOpenedNotFromEarlier() {
        var t = at(500)
        let m = openedDigest { t }
        t = at(600) // the digest sat unopened for a minute
        m.openBadge()
        t = at(600.2)
        m.toggleOpen() // the notch click also closes it
        XCTAssertNotNil(m.awayDigest, "a minute of the dot sitting there is not reading time")
    }

    func testADigestThatArrivesUnderAnOpenPanelCountsFromWhenItArrived() {
        var t = at(0)
        var locked = true
        let m = model(locked: { locked })
        m.dwellClock = { t }
        m.sweep(now: at(0))
        t = at(10); m.toggleOpen() // the user opened the empty panel while still away
        XCTAssertTrue(m.restOpen)
        stop(m, "a", at: at(50))
        locked = false; t = at(400); m.sweep(now: at(400)) // the return lands under the open panel
        XCTAssertNotNil(m.awayDigest)
        t = at(400.5)
        m.closeDetail()
        XCTAssertNotNil(m.awayDigest, "it had been on screen half a second")
    }

    func testTwoRefreshesWithNoNewEventsBuildTheDigestOnce() {
        let m = openedDigest { self.at(500) }
        let built = m.digestBuilds
        XCTAssertGreaterThan(built, 0)
        m.openBadge(); m.sweep(now: at(401)); m.sweep(now: at(402))
        XCTAssertEqual(m.digestBuilds, built, "opening and sweeping rebuilt nothing")
    }

    func testANewFinishRebuildsTheDigest() {
        let m = openedDigest { self.at(500) }
        let built = m.digestBuilds
        stop(m, "b", at: at(405)) // after the return: not folded in, but the inputs changed
        XCTAssertGreaterThan(m.digestBuilds, built)
        XCTAssertEqual(m.awayDigest?.rows.map(\.sessionId), ["a"])
    }

    func testReopeningAfterAQuickCloseStartsTheDwellAgain() {
        var t = at(500)
        let m = openedDigest { t }
        m.openBadge(); t = at(500.5); m.closeDetail() // too quick: stays
        t = at(900); m.openBadge()
        t = at(900.2); m.closeDetail()
        XCTAssertNotNil(m.awayDigest, "the second look lasted 0.2 s, not the 400 s since the first")
    }

    func testAResolvedFlagThatFlipsWithNoLabelChangeRebuildsTheDigest() {
        var queued: [() -> Void] = []
        // The git read answers with the very label already shown: no observer is told, but the row is now resolved.
        let cache = RepoIdentityCache(resolver: { RepoResolver.fallback(cwd: $0) }, background: { queued.append($0) }, deliver: { $0() })
        var locked = true
        let m = NotchModel(always: AlwaysStore(url: nil),
                           log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-test-\(UUID()).jsonl")),
                           identities: cache)
        m.awaySignal = { (locked, 0) }
        m.sweep(now: at(0)); stop(m, "a", at: at(50)); locked = false; m.sweep(now: at(400))
        XCTAssertEqual(m.awayDigest?.rows.first?.resolved, false)
        queued.forEach { $0() }
        m.sweep(now: at(401)); m.openBadge()
        XCTAssertEqual(m.awayDigest?.rows.first?.resolved, true, "a cached digest must not keep the old flag")
    }
}
