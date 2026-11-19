import Foundation

/// What the rest panel shows (#139): a count header and up to three sections, built from state the model already holds.
/// Pure: no UI types and no reply, prompt, question or command text (PDPA #30).
///
/// - **Needs you**: approvals and questions, asks that fell back to the terminal, and finished replies that end in a question.
/// - **Working**: sessions that are running.
/// - **Done**: finished threads from the last 30 minutes, newest first, at most 5.
///
/// A session is one row: the first section that claims it wins, in the order above. Only Needs-you rows have the prominent button.
public enum PanelSections {
    public enum Title: String, Equatable { case needsYou = "Needs you", working = "Working", done = "Done" }

    public enum Kind: Equatable { case approval, question, terminal, asksYou, working, finished }

    public struct Row: Identifiable, Equatable {
        public var id: String { sessionId }
        public let sessionId: String
        public let kind: Kind
        /// The one label every section uses: repo, plus a worktree tag only when it says something (never a hash).
        public let label: RepoLabel
        /// Whether git has answered for `label`; an unresolved repo must not claim an identity slot (#89).
        public let resolved: Bool
        /// From the live session when there is one, else from the finished thread.
        public let branch: String?
        public let at: Date
        public let host: HostInfo?
        /// Why the row is here, in a few words ("Approve Bash?", "Asked in terminal", "Asks you", "Reading", "Finished").
        public let detail: String
        /// The id of the pending request behind an approval or question row.
        public let pendingId: String?
        /// The prominent button: Needs-you rows only. The view still checks the host is running.
        public let hasButton: Bool
    }

    public struct Section: Equatable {
        public let title: Title
        public let rows: [Row]
    }

    public struct Result: Equatable {
        public let header: String
        public let sections: [Section]
        public var isEmpty: Bool { sections.isEmpty }
    }

    public static let doneCap = RecentList.cap
    public static let doneTTL = RecentList.ttl
    public static let workingTTL = RecentList.ttl

    /// `pending` is in rank order (see `WaitingList.items`). `label` is the model's resolved label for a cwd.
    public static func build(pending: [PendingRequest], terminal: [TerminalItem], done: [DoneItem], sessions: [SessionRow], recent: [RecentItem],
                             label: (_ cwd: String, _ project: String) -> RepoLabel, resolved: (_ cwd: String) -> Bool = { _ in true }, now: Date) -> Result {
        let live = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var claimed = Set<String>()
        func row(_ sid: String, _ kind: Kind, cwd: String, project: String, at: Date, host: HostInfo?, branch: String? = nil,
                 detail: String, pendingId: String? = nil, button: Bool) -> Row {
            make(sid, kind, label: label(cwd, project), resolved: resolved(cwd), at: at, host: host, branch: branch, detail: detail, pendingId: pendingId, button: button)
        }
        func make(_ sid: String, _ kind: Kind, label: RepoLabel, resolved: Bool, at: Date, host: HostInfo?, branch: String? = nil,
                  detail: String, pendingId: String? = nil, button: Bool) -> Row {
            Row(sessionId: sid, kind: kind, label: display(label), resolved: resolved, branch: live[sid]?.branch ?? branch,
                at: at, host: host ?? live[sid]?.host, detail: detail, pendingId: pendingId, hasButton: button)
        }

        var needs: [Row] = []
        for r in pending where claimed.insert(r.sessionId).inserted {
            needs.append(row(r.sessionId, r.questions != nil ? .question : .approval, cwd: r.cwd, project: r.project, at: r.createdAt, host: r.host,
                             branch: r.branch, detail: WaitingList.actionLabel(r), pendingId: r.id, button: true))
        }
        for t in terminal.sorted(by: { $0.at < $1.at }) where claimed.insert(t.sessionId).inserted {
            needs.append(row(t.sessionId, .terminal, cwd: t.cwd, project: t.project, at: t.at, host: t.host, detail: "Asked in terminal", button: true))
        }
        for d in done.sorted(by: { $0.at > $1.at }) where d.asksYou && claimed.insert(d.sessionId).inserted {
            needs.append(row(d.sessionId, .asksYou, cwd: d.cwd, project: d.project, at: d.at, host: d.host, branch: d.branch, detail: "Asks you", button: true))
        }

        var working: [Row] = []
        // A session that sent nothing for the Done window (Esc or a crash sends no Stop) is not counted as running.
        for s in sessions where s.status == .working && now.timeIntervalSince(s.updatedAt) <= workingTTL && claimed.insert(s.id).inserted {
            working.append(row(s.id, .working, cwd: s.cwd, project: s.project, at: s.updatedAt, host: s.host, branch: s.branch,
                               detail: LiveGlance.line(for: s, now: now).text, button: false))
        }

        // Done: what is still unclaimed, newest first, one row per session, within the TTL, capped.
        var finished: [Row] = []
        for d in done where !d.asksYou && !claimed.contains(d.sessionId) {
            finished.append(row(d.sessionId, .finished, cwd: d.cwd, project: d.project, at: d.at, host: d.host, branch: d.branch, detail: "Finished", button: false))
        }
        for r in recent where !claimed.contains(r.sessionId) && !finished.contains(where: { $0.sessionId == r.sessionId }) {
            finished.append(make(r.sessionId, .finished, label: r.label, resolved: r.resolved, at: r.at, host: r.host, detail: "Finished", button: false))
        }
        let doneRows = Array(finished.filter { now.timeIntervalSince($0.at) <= doneTTL }
            .enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at > $1.element.at : $0.offset < $1.offset }.map(\.element).prefix(doneCap))

        let sections = [Section(title: .needsYou, rows: needs), Section(title: .working, rows: working), Section(title: .done, rows: doneRows)]
            .filter { !$0.rows.isEmpty }
        return Result(header: header(needs: needs.count, working: working.count), sections: sections)
    }

    /// "2 need you · 3 working", "1 needs you", "3 working", or "All quiet".
    public static func header(needs: Int, working: Int) -> String {
        var parts: [String] = []
        if needs > 0 { parts.append(needs == 1 ? "1 needs you" : "\(needs) need you") }
        if working > 0 { parts.append("\(working) working") }
        return parts.isEmpty ? "All quiet" : parts.joined(separator: " · ")
    }

    // MARK: labels

    /// The label a row shows: a worktree tag that is only a hash says nothing, so it is dropped.
    public static func display(_ l: RepoLabel) -> RepoLabel {
        guard let w = l.worktree, isHashLike(w) else { return l }
        return RepoLabel(repo: l.repo)
    }

    /// A generated name no one would choose: its last `-`/`_` part is 10+ hex characters mixing digits and letters
    /// ("t3-3f9a6c1e-62fae7136250", "agent-a1b2c3d4e5f6"). Words like "deadbeef", "cafe1234" or "release-2026" are not.
    public static func isHashLike(_ name: String) -> Bool {
        guard let last = name.split(whereSeparator: { $0 == "-" || $0 == "_" }).last, last.count >= 10 else { return false }
        let hex = Set("0123456789abcdefABCDEF")
        guard last.allSatisfy({ hex.contains($0) }) else { return false }
        return last.contains(where: \.isNumber) && last.contains(where: \.isLetter)
    }
}
