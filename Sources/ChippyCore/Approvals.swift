import Foundation

public enum Decision: Equatable {
    case allow, deny, always

    /// Reply line for Claude Code's PermissionRequest hook (`behavior` shape, verified against claude 2.1.325).
    var reply: Data {
        let o: [String: Any] = self == .deny ? ["behavior": "deny", "message": "Denied from Chippy"] : ["behavior": "allow"]
        return try! JSONSerialization.data(withJSONObject: o)
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
    public let createdAt: Date

    public init(payload p: HookPayload, id: String = UUID().uuidString, now: Date = Date()) {
        self.id = id
        sessionId = p.sessionId
        project = p.project
        cwd = p.cwd
        toolName = p.toolName ?? "tool"
        ask = Self.oneLine(tool: p.toolName ?? "tool", input: p.toolInput)
        createdAt = now
    }

    static func oneLine(tool: String, input: [String: Any]) -> String {
        let detail: String
        if let c = input["command"] as? String { detail = c }
        else if let f = input["file_path"] as? String { detail = f }
        else if let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                let s = String(data: d, encoding: .utf8), s != "{}" { detail = s }
        else { detail = "" }
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

    static func key(_ r: PendingRequest) -> String { [r.cwd, r.toolName, r.ask].joined(separator: "\u{1F}") }
    public func contains(_ r: PendingRequest) -> Bool { keys.contains(Self.key(r)) }

    public func insert(_ r: PendingRequest) {
        keys.insert(Self.key(r))
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(keys.sorted()).write(to: url, options: .atomic)
    }
}
