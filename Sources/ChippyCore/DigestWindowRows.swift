import Foundation

/// The rows of the menu bar "While you were away" window (#167). Built from the digest the model already holds, so the
/// window and the notch panel can never disagree: same rows, same order, no cap. Repo, worktree, status and age only;
/// like `DigestRow` it has nowhere to put a prompt, reply, question or command (PDPA #30).
public struct DigestWindowRow: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let statusText: String
    public let needsYou: Bool
    public let at: Date
    /// Where Open goes; nil for a Recent-only row, which has no button.
    public let target: WaitingTarget?
    public let resolved: Bool
    public let repo: String
}

public enum DigestWindowRows {
    public static func statusText(_ s: DigestRow.Status) -> String {
        switch s { case .needsYou: return "asked in terminal"; case .asksYou: return "asks you"; case .finished: return "finished" }
    }

    /// Every row of the digest, in its order. `nil` (nothing to report) gives no rows.
    public static func rows(from digest: AwayDigest.Result?) -> [DigestWindowRow] {
        (digest?.rows ?? []).map { r in
            DigestWindowRow(id: r.sessionId, name: r.worktree.map { "\(r.repo) / \($0)" } ?? r.repo, statusText: statusText(r.status),
                            needsYou: r.status == .needsYou, at: r.at, target: r.target, resolved: r.resolved, repo: r.repo)
        }
    }

    public static func title(_ digest: AwayDigest.Result?) -> String {
        guard let d = digest else { return "Nothing to report" }
        return "While you were away (\(d.total))"
    }
}
