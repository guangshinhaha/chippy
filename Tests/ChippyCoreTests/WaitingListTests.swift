import Darwin
import XCTest
@testable import ChippyCore

/// Issue #53: the waiting list behind the count badge.
final class WaitingListTests: XCTestCase {
    private func model() -> NotchModel {
        NotchModel(always: AlwaysStore(url: nil),
                   log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-wl-\(UUID()).jsonl")))
    }
    private func conn() -> Connection {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        return Connection(fd: fds[0])
    }
    private func approval(_ m: NotchModel, _ sid: String, cwd: String = "/w/api", secret: String = "rm -rf /secret") {
        m.receiveApproval(HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"PermissionRequest","cwd":"\#(cwd)","tool_name":"Bash","tool_input":{"command":"\#(secret)"}}"#.utf8))!, conn())
    }
    private func question(_ m: NotchModel, _ sid: String, cwd: String = "/w/qs", two: Bool = true) {
        let qs: [[String: Any]] = [["question": "Q1?", "header": "A", "multiSelect": false, "options": [["label": "x", "description": ""], ["label": "y", "description": ""]]]]
            + (two ? [["question": "Q2?", "header": "B", "multiSelect": false, "options": [["label": "p", "description": ""], ["label": "q", "description": ""]]]] : [])
        let json: [String: Any] = ["session_id": sid, "cwd": cwd, "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": ["questions": qs]]
        m.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: json))!, conn())
    }
    private func stop(_ m: NotchModel, _ sid: String, cwd: String = "/w/done", at: Date = Date()) {
        m.apply(HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"Stop","cwd":"\#(cwd)"}"#.utf8))!, now: at)
    }

    // MARK: pure

    func testRepoNameIsLastComponentOnly() {
        XCTAssertEqual(WaitingList.repoName(cwd: "/Users/x/work/api"), "api")
        XCTAssertEqual(WaitingList.repoName(cwd: "/Users/x/work/api/"), "api")
        XCTAssertEqual(WaitingList.repoName(cwd: "/"), "unknown")
        XCTAssertEqual(WaitingList.repoName(cwd: ""), "unknown")
    }

    func testOrderBlockingFirstOldestFirstThenDoneNewestFirst() {
        let m = model()
        let t0 = Date()
        stop(m, "d1", cwd: "/w/d1", at: t0)
        stop(m, "d2", cwd: "/w/d2", at: t0.addingTimeInterval(5))
        approval(m, "a1")
        question(m, "q1")
        let items = m.waitingItems
        XCTAssertEqual(items.map(\.kind), [.approval, .question, .done, .done])
        XCTAssertEqual(items.suffix(2).map(\.repo), ["d2", "d1"]) // newest done first
        XCTAssertEqual(items[0].repo, "api")
        XCTAssertEqual(items[1].repo, "qs")
    }

    func testRowsCarryNoQuestionOrCommandText() {
        let m = model()
        approval(m, "a", secret: "curl https://secret.example/token")
        question(m, "q")
        stop(m, "d")
        for item in m.waitingItems {
            let dump = "\(item)"
            XCTAssertFalse(dump.contains("secret"), dump)
            XCTAssertFalse(dump.contains("Q1?"), dump)
            XCTAssertFalse(dump.contains("/w/"), dump) // repo name only, never the path
        }
    }

    func testMoveClampsAndStartsAtTheEdgeMovedFrom() {
        let items = [WaitingTarget.pending("a"), .pending("b"), .done("c")].map { WaitingItem(target: $0, kind: .approval, repo: "r", at: Date()) }
        XCTAssertEqual(WaitingList.move(nil, in: items, by: 1), .pending("a"))
        XCTAssertEqual(WaitingList.move(nil, in: items, by: -1), .done("c"))
        XCTAssertEqual(WaitingList.move(.pending("a"), in: items, by: 1), .pending("b"))
        XCTAssertEqual(WaitingList.move(.done("c"), in: items, by: 1), .done("c"))       // no wrap
        XCTAssertEqual(WaitingList.move(.pending("a"), in: items, by: -1), .pending("a"))
        XCTAssertEqual(WaitingList.move(.pending("gone"), in: items, by: 1), .pending("a"))
        XCTAssertNil(WaitingList.move(nil, in: [], by: 1))
    }

    func testReconcileKeepsOrFallsBackToFirst() {
        let items = [WaitingTarget.pending("a"), .done("c")].map { WaitingItem(target: $0, kind: .done, repo: "r", at: Date()) }
        XCTAssertEqual(WaitingList.reconcile(.done("c"), in: items), .done("c"))
        XCTAssertEqual(WaitingList.reconcile(.done("zzz"), in: items), .pending("a"))
        XCTAssertNil(WaitingList.reconcile(.done("c"), in: []))
    }

    func testAgeLabels() {
        let now = Date()
        XCTAssertEqual(WaitingList.age(since: now, now: now), "now")
        XCTAssertEqual(WaitingList.age(since: now.addingTimeInterval(-42), now: now), "42s")
        XCTAssertEqual(WaitingList.age(since: now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(WaitingList.age(since: now.addingTimeInterval(-7300), now: now), "2h")
        XCTAssertEqual(WaitingList.age(since: now.addingTimeInterval(-200_000), now: now), "2d")
        XCTAssertEqual(WaitingList.age(since: now.addingTimeInterval(60), now: now), "now") // clock skew
    }

    // MARK: model

    func testBadgeTapOpensListAndEscClosesIt() {
        let m = model()
        stop(m, "d1"); stop(m, "d2")
        m.openList()
        XCTAssertTrue(m.listOpen)
        XCTAssertEqual(m.density, .expanded)
        XCTAssertFalse(m.tall)
        XCTAssertEqual(m.listSelection, .done("d2")) // newest first
        m.closeDetail()                               // Esc / click outside
        XCTAssertFalse(m.listOpen)
        XCTAssertEqual(m.doneItems.count, 2)          // nothing was dismissed
    }

    func testArrowsAndReturnOpenTheDoneDetail() {
        let m = model()
        stop(m, "d1"); stop(m, "d2")
        m.openList()
        m.moveSelection(1)
        XCTAssertEqual(m.listSelection, .done("d1"))
        m.moveSelection(1)
        XCTAssertEqual(m.listSelection, .done("d1")) // clamped
        m.activateSelection()
        XCTAssertFalse(m.listOpen)
        XCTAssertEqual(m.shownDone?.sessionId, "d1") // the older chip, not the newest
        XCTAssertTrue(m.tall)
        m.closeDetail()
        XCTAssertNil(m.shownDone)
        XCTAssertEqual(m.density, .collapsed)
    }

    func testJumpToASecondApprovalShowsItAndKeysTargetIt() {
        let m = model()
        approval(m, "a", cwd: "/w/one"); approval(m, "b", cwd: "/w/two")
        XCTAssertEqual(m.shownPending?.sessionId, "a")
        m.openList()
        XCTAssertNil(m.shownPending)                  // shortcuts act on nothing while the list covers the card
        m.activate(m.waitingItems[1].target)
        XCTAssertEqual(m.shownPending?.sessionId, "b")
        m.resolve(m.shownPending!.id, .allow)
        XCTAssertEqual(m.shownPending?.sessionId, "a") // focus gone: back to the queue head
    }

    func testDoneDetailOverAnApprovalIsNotAnApprovalTarget() {
        let m = model()
        approval(m, "a"); stop(m, "d")
        m.openList()
        m.activate(.done("d"))
        XCTAssertEqual(m.shownDone?.sessionId, "d")
        XCTAssertNil(m.shownPending)                  // ⌃⌥Y must not approve a card that is not on screen
        m.closeDetail()
        XCTAssertEqual(m.shownPending?.sessionId, "a")
    }

    func testPartialAnswersSurviveLeavingTheCardAndAreDroppedOnResolve() {
        let m = model()
        question(m, "q"); approval(m, "a")
        let q = m.pending[0]
        m.savePartial(q.id, step: 1, answers: ["Q1?": "x"])
        m.openList(); m.activate(m.waitingItems[1].target) // go look at the approval
        XCTAssertEqual(m.shownPending?.sessionId, "a")
        m.openList(); m.activate(.pending(q.id))           // and back
        XCTAssertEqual(m.partials[q.id], PartialAnswers(step: 1, answers: ["Q1?": "x"]))
        m.handBack(q.id)
        XCTAssertNil(m.partials[q.id])
    }

    func testListClosesItselfWhenTheLastItemGoes() {
        let m = model()
        stop(m, "d")
        m.openList()
        m.dismissDone("d")
        XCTAssertFalse(m.listOpen)
        XCTAssertFalse(m.visible)
    }

    func testSelectionFollowsWhenTheHighlightedItemDisappears() {
        let m = model()
        stop(m, "d1"); stop(m, "d2")
        m.openList()
        XCTAssertEqual(m.listSelection, .done("d2"))
        m.dismissDone("d2")
        XCTAssertEqual(m.listSelection, .done("d1"))
    }

    func testListNeverOpensWhenNothingWaitsAndBlankClicksDoNotToggleIt() {
        let m = model()
        m.openList()
        XCTAssertFalse(m.listOpen)
        stop(m, "d")
        m.openList()
        m.toggleOpen()                                 // a click on empty panel space
        XCTAssertTrue(m.listOpen)
        XCTAssertFalse(m.doneOpen)
    }

    func testHoverIsIgnoredWhileTheListIsOpen() {
        var now: TimeInterval = 100
        let m = NotchModel(always: AlwaysStore(url: nil),
                           log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("chippy-wl-\(UUID()).jsonl")),
                           clock: { now })
        stop(m, "d")
        m.openList()
        m.setHover(true); m.setHover(false)
        XCTAssertEqual(m.density, .expanded)
        now += 100
        m.sweep()
        XCTAssertTrue(m.listOpen)
        XCTAssertEqual(m.density, .expanded)
    }

    func testNewApprovalTakesOverFromAFocusedDoneDetail() {
        let m = model()
        stop(m, "d")
        m.openList(); m.activate(.done("d"))
        XCTAssertNotNil(m.shownDone)
        approval(m, "a")
        XCTAssertNil(m.focus)
        XCTAssertFalse(m.doneOpen)
        XCTAssertNil(m.shownDone)
        XCTAssertEqual(m.shownPending?.sessionId, "a") // so the shortcuts have a card to act on
        XCTAssertFalse(m.tall)
    }

    func testToggleOpenFoldsAFocusedDoneWithoutDrift() {
        let m = model()
        stop(m, "d1"); stop(m, "d2")
        m.openList(); m.activate(.done("d1"))
        m.toggleOpen()
        XCTAssertNil(m.focus)
        XCTAssertFalse(m.doneOpen)
        XCTAssertEqual(m.density, .collapsed)
        m.toggleOpen()                                  // a normal open still works afterwards
        XCTAssertTrue(m.doneOpen)
        XCTAssertNil(m.shownDone)
    }

    func testDoneOpenResetsWhenFocusedChipGoesEvenWithAnApprovalWaiting() {
        let m = model()
        stop(m, "d1"); stop(m, "d2")
        m.openList(); m.activate(.done("d1"))
        approval(m, "a")                                // takes over; refocus the chip afterwards
        m.openList(); m.activate(.done("d1"))
        XCTAssertTrue(m.doneOpen)
        m.dismissDone("d1")
        XCTAssertNil(m.focus)
        XCTAssertFalse(m.doneOpen)
        XCTAssertEqual(m.shownPending?.sessionId, "a")
    }

    func testPartialsClearedWhenQuestionIsAnswered() {
        let m = model()
        question(m, "q", two: false)
        let id = m.pending[0].id
        m.savePartial(id, step: 0, answers: ["Q1?": "x"])
        XCTAssertNotNil(m.partials[id])
        m.answer(id, ["Q1?": "x"])
        XCTAssertNil(m.partials[id])
        m.savePartial(id, step: 0, answers: ["Q1?": "x"]) // a late save for a gone request is ignored
        XCTAssertNil(m.partials[id])
    }

    func testWaitingItemsStayCurrentAfterEveryChange() {
        let m = model()
        XCTAssertTrue(m.waitingItems.isEmpty)
        stop(m, "d"); XCTAssertEqual(m.waitingItems.count, 1)
        approval(m, "a"); XCTAssertEqual(m.waitingItems.count, 2)
        m.dismissDone("d"); XCTAssertEqual(m.waitingItems.count, 1)
        m.handBack(m.pending[0].id); XCTAssertTrue(m.waitingItems.isEmpty)
    }
}
