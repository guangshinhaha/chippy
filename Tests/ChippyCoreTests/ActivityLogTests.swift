import XCTest
@testable import ChippyCore

/// Issue #168: a content-free activity log so the away digest survives a restart.
final class ActivityLogTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000) // whole seconds: the log stores ISO-8601 seconds
    func at(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    func log(_ name: String = "activity") -> ActivityLog { ActivityLog(url: scratchURL("chippy-\(name)-\(UUID())/activity.jsonl")) }

    // Fixture: every kind of content text carries a marker.
    let marker = "SECRETMARK"
    func done(_ sid: String, _ cwd: String, _ s: TimeInterval, asks: Bool = false) -> DoneItem {
        DoneItem(sessionId: sid, project: cwd, branch: "\(marker)-branch", files: 0, added: 0, removed: 0,
                 reply: asks ? "\(marker)-REPLY. Shall I \(marker)-QUESTION?" : "\(marker)-REPLY", prompt: "\(marker)-PROMPT", at: at(s), cwd: cwd)
    }
    func term(_ sid: String, _ cwd: String, _ s: TimeInterval) -> TerminalItem { TerminalItem(sessionId: sid, project: cwd, at: at(s), tool: "\(marker)-COMMAND", cwd: cwd) }

    // MARK: no content in the file

    func testTheFileHoldsNoPromptReplyQuestionCommandPathOrSessionId() throws {
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("ev-\(UUID()).jsonl")),
                           identities: RepoIdentityCache(resolver: { RepoResolver.fallback(cwd: $0) }, background: { $0() }, deliver: { $0() }),
                           activity: log())
        // Drive the real paths: a terminal ask and two Stops (one asks a question), with the marker everywhere content can go.
        let sidA = "\(marker)-SESSION-A", sidB = "\(marker)-SESSION-B"
        for (sid, reply) in [(sidA, "\(marker)-REPLY done."), (sidB, "\(marker)-REPLY. Shall I \(marker)-QUESTION?")] {
            m.apply(HookPayload(json: try JSONSerialization.data(withJSONObject: [
                "session_id": sid, "hook_event_name": "UserPromptSubmit", "cwd": "/Users/x/\(marker)-secretdir/govapps", "prompt": "\(marker)-PROMPT"]))!, now: at(1))
            m.apply(HookPayload(json: try JSONSerialization.data(withJSONObject: [
                "session_id": sid, "hook_event_name": "Stop", "cwd": "/Users/x/\(marker)-secretdir/govapps", "last_assistant_message": reply]))!, now: at(2))
        }
        let req = PendingRequest(payload: HookPayload(json: try JSONSerialization.data(withJSONObject: [
            "session_id": sidA, "hook_event_name": "PermissionRequest", "cwd": "/Users/x/\(marker)-secretdir/govapps",
            "tool_name": "\(marker)-COMMAND", "tool_input": ["command": "\(marker)-cmd"]]))!, now: at(3))
        m.debugNoteTerminal(req, now: at(3))
        let url = m.debugActivityURL!
        let bytes = try String(decoding: Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(bytes.isEmpty, "the events were written")
        XCTAssertEqual(bytes.split(separator: "\n").count, 3)
        XCTAssertFalse(bytes.contains(marker), bytes)
        XCTAssertFalse(bytes.contains("/Users"), "no path")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o600)
    }

    func testTheSessionKeyIsASaltedHashNotTheId() {
        let l = log()
        let k = l.hash("session-123")
        XCTAssertEqual(k.count, 16)
        XCTAssertFalse(k.contains("session"))
        XCTAssertEqual(k, l.hash("session-123"), "stable, so one session stays one row")
        XCTAssertEqual(k, ActivityLog(url: l.url).hash("session-123"), "the salt is kept, so it survives a restart")
        XCTAssertNotEqual(k, log().hash("session-123"), "another install keys differently")
    }

    // MARK: digest from the log == digest from memory

    func testTheLogBuildsTheSameRowsInTheSameOrderAsMemory() {
        let l = log()
        let cache = RepoIdentityCache(resolver: { RepoResolver.fallback(cwd: $0) }, background: { $0() }, deliver: { $0() })
        let terminal = [term("t2", "p-t2", 30), term("t1", "p-t1", 10)]
        let finished = [done("d1", "p-d1", 20), done("d2", "p-d2", 40, asks: true), done("d3", "p-d3", 25)]
        let memory = AwayDigest.build(since: at(0), until: at(100), terminal: terminal, done: finished, recent: [],
                                      label: { cache.label(cwd: $0, project: $1) }, cap: .max)
        for t in terminal { l.record(.needsYou, sessionId: t.sessionId, label: RepoLabel(repo: t.project), at: t.at) }
        for d in finished { l.record(d.asksYou ? .asksYou : .finished, sessionId: d.sessionId, label: RepoLabel(repo: d.project), at: d.at) }
        let fromLog = AwayDigest.build(logged: l.events(), since: at(0), until: at(100))
        func shape(_ r: AwayDigest.Result) -> [String] { r.rows.map { "\($0.status.rawValue)|\($0.repo)|\($0.worktree ?? "-")|\($0.at.timeIntervalSince1970)" } }
        XCTAssertEqual(shape(fromLog), shape(memory))
        XCTAssertEqual(fromLog.rows.count, 5)
        XCTAssertTrue(fromLog.rows.allSatisfy { $0.target == nil && $0.host == nil && $0.ended }, "no live target: no Open button, and the row says ended")
    }

    func testTheRangeAndOneRowPerSessionApply() {
        let l = log()
        l.record(.finished, sessionId: "a", label: RepoLabel(repo: "early"), at: at(-50))
        l.record(.needsYou, sessionId: "b", label: RepoLabel(repo: "b-repo"), at: at(10))
        l.record(.finished, sessionId: "b", label: RepoLabel(repo: "b-repo"), at: at(20)) // the latest event of a session wins
        l.record(.finished, sessionId: "c", label: RepoLabel(repo: "late"), at: at(500))
        let d = AwayDigest.build(logged: l.events(), since: at(0), until: at(100))
        XCTAssertEqual(d.rows.map(\.repo), ["b-repo"])
        XCTAssertEqual(d.rows.first?.status, .finished)
    }

    func testInMemoryRowsWinOverTheLoggedOneForTheSameSession() {
        let l = log()
        l.record(.finished, sessionId: "s", label: RepoLabel(repo: "r"), at: at(10))
        let d = AwayDigest.build(since: at(0), until: at(100), terminal: [], done: [done("s", "r", 12)], recent: [], cap: .max,
                                 logged: l.events(), hash: { l.hash($0) })
        XCTAssertEqual(d.rows.count, 1)
        XCTAssertNotNil(d.rows.first?.target, "the live chip, with its Open button")
        XCTAssertFalse(d.rows[0].ended)
    }

    // MARK: restart

    func testARestartRebuildsTheDigestForTheAwayPeriodItWasIn() {
        let cache = { RepoIdentityCache(resolver: { RepoResolver.fallback(cwd: $0) }, background: { $0() }, deliver: { $0() }) }
        let l = log()
        let first = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("ev-\(UUID()).jsonl")), identities: cache(), activity: l)
        var locked = true
        first.awaySignal = { (locked, 0) }
        let t = Date().addingTimeInterval(-1000)
        first.sweep(now: t)
        for sid in ["a", "b"] {
            first.apply(HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"Stop","cwd":"/x/\#(sid)-repo","last_assistant_message":"SECRET"}"#.utf8))!, now: t.addingTimeInterval(50))
        }
        locked = false; first.sweep(now: t.addingTimeInterval(400))
        let before = first.awayDigest
        XCTAssertEqual(before?.rows.count, 2)
        // Quit and relaunch: a new model, new in-memory state, the same files.
        let second = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("ev-\(UUID()).jsonl")), identities: cache(), activity: ActivityLog(url: l.url))
        XCTAssertEqual(second.awayDigest?.rows.map(\.repo).sorted(), before?.rows.map(\.repo).sorted())
        XCTAssertEqual(second.awayDigest?.rows.count, 2)
        XCTAssertTrue(second.awayDigest?.rows.allSatisfy { $0.ended && $0.target == nil } ?? false)
        XCTAssertEqual(DigestWindowRows.rows(from: second.awayDigest).map(\.ended), [true, true], "the window says ended")
    }

    func testADismissedDigestStaysGoneAfterARestart() {
        let l = log()
        let cache = { RepoIdentityCache(resolver: { RepoResolver.fallback(cwd: $0) }, background: { $0() }, deliver: { $0() }) }
        let first = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("ev-\(UUID()).jsonl")), identities: cache(), activity: l)
        var locked = true
        first.awaySignal = { (locked, 0) }
        let t = Date().addingTimeInterval(-1000)
        first.sweep(now: t)
        first.apply(HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"Stop","cwd":"/x/p"}"#.utf8))!, now: t.addingTimeInterval(50))
        locked = false; first.sweep(now: t.addingTimeInterval(400))
        XCTAssertNotNil(first.awayDigest)
        first.dismissAwayDigest()
        let second = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("ev-\(UUID()).jsonl")), identities: cache(), activity: ActivityLog(url: l.url))
        XCTAssertNil(second.awayDigest)
    }

    func testWithNoLogNothingIsWritten() {
        let m = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: scratchURL("ev-\(UUID()).jsonl")))
        m.apply(HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"Stop","cwd":"/x/p"}"#.utf8))!)
        XCTAssertNil(m.debugActivityURL)
    }

    // MARK: cap

    func testTrimDropsOldLinesAndKeepsTheNewestWithinTheCap() {
        let l = log()
        let now = at(0)
        for i in 0..<5 { l.record(.finished, sessionId: "old\(i)", label: RepoLabel(repo: "old"), at: now.addingTimeInterval(-20 * 86_400)) }
        for i in 0..<30 { l.record(.finished, sessionId: "s\(i)", label: RepoLabel(repo: "r\(i)"), at: now.addingTimeInterval(-TimeInterval(100 - i))) }
        l.trim(now: now, maxAge: 14 * 86_400, maxLines: 20)
        let kept = l.events()
        XCTAssertEqual(kept.count, 20, "older than 14 days gone, then the newest 20 of the rest")
        XCTAssertEqual(kept.map(\.repo), (10..<30).map { "r\($0)" })
        let attrs = try? FileManager.default.attributesOfItem(atPath: l.url.path)
        XCTAssertEqual((attrs?[.posixPermissions] as? Int) ?? 0, 0o600, "a rewritten file keeps the mode")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.url.path + ".tmp"))
    }

    func testTrimLeavesAShortRecentLogAlone() {
        let l = log()
        l.record(.finished, sessionId: "a", label: RepoLabel(repo: "r"), at: at(-10))
        let before = try? Data(contentsOf: l.url)
        l.trim(now: at(0))
        XCTAssertEqual(try? Data(contentsOf: l.url), before)
    }
}
