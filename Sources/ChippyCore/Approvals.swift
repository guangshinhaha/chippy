import CryptoKit
import Foundation

public enum Decision: Equatable {
    case allow, deny, always

    /// Reply line for Claude Code's PermissionRequest hook (`behavior` shape, verified against claude 2.1.325).
    var reply: Data {
        let o: [String: Any] = self == .deny ? ["behavior": "deny", "message": "Denied from Chippy"] : ["behavior": "allow"]
        return try! JSONSerialization.data(withJSONObject: o)
    }
}

/// One of Claude's own multiple-choice questions (AskUserQuestion). Single- and multi-select are answerable from the notch.
public struct AskQuestion: Equatable {
    public struct Option: Equatable { public let label: String; public let description: String }
    public let question: String
    public let header: String
    public let options: [Option]
    public let multiSelect: Bool

    /// nil unless every question is well-formed (text, unique non-empty option labels, at least one option), so anything else goes to the terminal.
    static func parse(_ input: [String: Any]) -> [AskQuestion]? {
        guard let qs = input["questions"] as? [[String: Any]], !qs.isEmpty else { return nil }
        var out: [AskQuestion] = []
        for q in qs {
            guard let text = q["question"] as? String,
                  let opts = q["options"] as? [[String: Any]], !opts.isEmpty else { return nil }
            let options = opts.compactMap { o in (o["label"] as? String).map { Option(label: $0, description: o["description"] as? String ?? "") } }
            guard options.count == opts.count, Set(options.map(\.label)).count == options.count,
                  !options.contains(where: { $0.label.isEmpty }) else { return nil }
            // A ", " inside a label would make the joined multi-select answer ambiguous: leave those to the terminal.
            if q["multiSelect"] as? Bool == true, options.contains(where: { $0.label.contains(", ") }) { return nil }
            out.append(AskQuestion(question: text, header: q["header"] as? String ?? "", options: options, multiSelect: q["multiSelect"] as? Bool == true))
        }
        guard Set(out.map(\.question)).count == out.count else { return nil } // answers are keyed by question text
        return out
    }
}

public struct PendingRequest: Identifiable, Equatable {
    public let id: String
    public let sessionId: String
    public let project: String
    public let cwd: String
    public let toolName: String
    /// One-line ask, verbatim from the tool input (e.g. "Bash: npm install").
    public let ask: String
    /// One-line plain intent shown above the raw detail; nil keeps the plain card.
    public let intent: ApprovalIntent?
    public let createdAt: Date
    public let branch: String?
    /// Full command / path / input, for the detail card (capped). In memory only.
    public let detail: String
    /// The thread's last prompt, for context. In memory only.
    public var lastPrompt: String?
    /// Claude's words just before an AskUserQuestion, from the transcript. In memory only.
    public let leadIn: String?
    /// Set for an answerable AskUserQuestion; the card shows options instead of Allow/Deny.
    public let questions: [AskQuestion]?
    /// SHA-256 of the full tool input, so "Always" on an Edit can't cover other content in the same file.
    let inputDigest: String

    public init(payload p: HookPayload, id: String = UUID().uuidString, now: Date = Date()) {
        self.id = id
        sessionId = p.sessionId
        project = p.project
        cwd = p.cwd
        toolName = p.toolName ?? "tool"
        ask = Self.oneLine(tool: p.toolName ?? "tool", input: p.toolInput)
        intent = p.toolName == "AskUserQuestion" ? nil : ApprovalIntent.make(tool: p.toolName ?? "tool", input: p.toolInput)
        createdAt = now
        leadIn = p.toolName == "AskUserQuestion" ? p.leadIn : nil
        branch = p.branch
        questions = p.toolName == "AskUserQuestion" ? AskQuestion.parse(p.toolInput) : nil
        detail = ApprovalIntent.headTail(ApprovalIntent.reveal(Self.rawDetail(p.toolInput)))
        let canon = (try? JSONSerialization.data(withJSONObject: p.toolInput, options: [.sortedKeys])) ?? Data()
        inputDigest = AlwaysStore.sha256(canon)
    }

    static func rawDetail(_ input: [String: Any]) -> String {
        let detail: String
        if let c = input["command"] as? String { detail = c }
        else if let f = input["file_path"] as? String { detail = f }
        else if let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                let s = String(data: d, encoding: .utf8), s != "{}" { detail = s }
        else { detail = "" }
        return detail
    }

    static func oneLine(tool: String, input: [String: Any]) -> String {
        let detail = ApprovalIntent.reveal(rawDetail(input)) // hidden scalars shown, never acting, in the ask too
        let flat = detail.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        return detail.isEmpty ? tool : "\(tool): \(flat)"
    }
}

/// "Always" decisions, per project and exact ask, persisted so they survive restarts.
public final class AlwaysStore {
    private var keys: Set<String>
    private let url: URL?

    public init(url: URL? = ChippyPaths.supportDir.appendingPathComponent("always.json")) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([String].self, from: d) {
            keys = Set(a)
        } else { keys = [] }
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Hashed, so always.json never holds raw commands, paths or anything pasted into them (PDPA).
    static func key(_ r: PendingRequest) -> String {
        sha256(Data([r.cwd, r.toolName, r.ask, r.inputDigest].joined(separator: "\u{1F}").utf8))
    }
    public func contains(_ r: PendingRequest) -> Bool { keys.contains(Self.key(r)) }

    public func insert(_ r: PendingRequest) {
        keys.insert(Self.key(r))
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(keys.sorted()).write(to: url, options: .atomic)
    }
}
