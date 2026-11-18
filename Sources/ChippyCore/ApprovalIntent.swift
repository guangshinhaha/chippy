import Foundation

/// One plain line saying what a tool call does, shown above the raw command on the approval card.
/// Built only from what the payload carries: never invents a reason.
public enum ApprovalIntent {
    public static let maxLength = 100

    public static func line(tool: String, input: [String: Any]) -> String {
        func str(_ k: String) -> String? {
            guard let s = (input[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        func file(_ s: String) -> String { s.hasPrefix("/") ? (s as NSString).lastPathComponent : s }
        let text: String
        switch tool {
        case "Bash":
            // The model's own description is the one place a "why" is truly carried.
            text = str("description") ?? "Run a shell command"
        case "Edit", "MultiEdit": text = str("file_path").map { "Edit \(file($0))" } ?? "Edit a file"
        case "Write": text = str("file_path").map { "Write \(file($0))" } ?? "Write a file"
        case "NotebookEdit": text = str("notebook_path").map { "Edit notebook \(file($0))" } ?? "Edit a notebook"
        case "Read": text = str("file_path").map { "Read \(file($0))" } ?? "Read a file"
        case "WebFetch": text = str("url").map { "Fetch \($0)" } ?? "Fetch a web page"
        case "WebSearch": text = str("query").map { "Search the web for \"\($0)\"" } ?? "Search the web"
        case "Glob": text = str("pattern").map { "Find files matching \($0)" } ?? "Find files"
        case "Grep": text = str("pattern").map { "Search files for \"\($0)\"" } ?? "Search files"
        default:
            let arg = ["command", "file_path", "path", "url", "query", "pattern", "name"].lazy.compactMap { str($0) }.first
            text = arg.map { "Use \(tool): \($0)" } ?? "Use \(tool)"
        }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > maxLength ? String(flat.prefix(maxLength - 1)) + "…" : flat
    }
}
