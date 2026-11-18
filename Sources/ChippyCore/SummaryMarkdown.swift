import Foundation

/// Light markdown for the finished-card summary (#98b). Pure and on-device; nothing is logged or sent (PDPA).
/// Supports bold, inline code, bullets, headings (as bold lines), fenced code and links (label only). Every raw marker is dropped.
public enum SummaryMarkdown {
    public enum Run: Equatable {
        case text(String), bold(String), code(String)

        public var string: String {
            switch self { case .text(let s), .bold(let s), .code(let s): return s }
        }
        func with(_ s: String) -> Run {
            switch self { case .text: return .text(s); case .bold: return .bold(s); case .code: return .code(s) }
        }
    }
    public enum Block: Equatable {
        case paragraph([Run])
        case bullet([Run])
        case code(String)

        /// The block's text with no styling, for tests and accessibility.
        public var plain: String {
            switch self {
            case .paragraph(let r), .bullet(let r): return r.map(\.string).joined()
            case .code(let c): return c
            }
        }
    }

    /// Outcome first, then the rest folded away.
    public struct Doc: Equatable {
        public var outcome: [Run]
        public var details: [Block]
        public var outcomePlain: String { outcome.map(\.string).joined() }
    }

    static let maxInput = 20_000
    static let maxOutcome = 200
    static let maxCodeLines = 12

    /// Outcome = the first block, cut at its first sentence when long; the remainder leads the details.
    public static func doc(_ reply: String?) -> Doc? {
        var blocks = parse(reply)
        guard !blocks.isEmpty else { return nil }
        let first = blocks.removeFirst()
        switch first {
        case .paragraph(let runs), .bullet(let runs):
            let (head, tail) = splitOutcome(runs)
            return Doc(outcome: head, details: (tail.map { [Block.paragraph($0)] } ?? []) + blocks)
        case .code:
            return Doc(outcome: [], details: [first] + blocks)
        }
    }

    private static func splitOutcome(_ runs: [Run]) -> ([Run], [Run]?) {
        let plain = runs.map(\.string).joined()
        guard plain.count > maxOutcome / 2 else { return (runs, nil) }
        // First sentence end within the cap, found on the plain text, then mapped back onto the runs.
        let chars = Array(plain)
        var cut: Int? = nil
        var i = 8
        while i < min(chars.count - 1, maxOutcome) {
            if ".!?".contains(chars[i]), chars[i + 1].isWhitespace { cut = i + 1; break }
            i += 1
        }
        var ellipsis = false
        if cut == nil, chars.count > maxOutcome { cut = maxOutcome; ellipsis = true }
        guard let cut, cut < chars.count else { return (runs, nil) }
        var head: [Run] = [], tail: [Run] = []
        var seen = 0
        for r in runs {
            let s = r.string, n = s.count
            if seen + n <= cut { head.append(r) }
            else if seen >= cut { tail.append(r) }
            else {
                let k = cut - seen
                head.append(r.with(String(s.prefix(k))))
                tail.append(r.with(String(s.dropFirst(k))))
            }
            seen += n
        }
        if ellipsis { head.append(.text("…")) }
        tail = trimLeading(tail)
        return (head, tail.isEmpty ? nil : tail)
    }

    private static func trimLeading(_ runs: [Run]) -> [Run] {
        var out = runs
        while let f = out.first {
            let t = String(f.string.drop(while: \.isWhitespace))
            if t.isEmpty { out.removeFirst() } else { out[0] = f.with(t); break }
        }
        return out
    }

    public static func parse(_ reply: String?) -> [Block] {
        guard let reply else { return [] }
        let lines = String(reply.prefix(maxInput)).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        func codeBlock(_ c: [String]) -> Block {
            .code(c.prefix(maxCodeLines).joined(separator: "\n") + (c.count > maxCodeLines ? "\n…" : ""))
        }
        func flush() {
            if !para.isEmpty {
                let runs = inline(para.joined(separator: " "))
                if !runs.isEmpty { blocks.append(.paragraph(runs)) }
                para = []
            }
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { blocks.append(codeBlock(c)); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty || isRule(line) { flush(); continue }
            if let b = bulletBody(line) {
                flush()
                let runs = inline(b)
                if !runs.isEmpty { blocks.append(.bullet(runs)) }
            } else if let h = headingBody(line) {
                flush()
                let t = inline(h).map(\.string).joined()
                if !t.isEmpty { blocks.append(.paragraph([.bold(t)])) }
            } else {
                para.append(line.hasPrefix(">") ? String(line.drop(while: { $0 == ">" || $0 == " " })) : line)
            }
        }
        flush()
        if let c = code, !c.isEmpty { blocks.append(codeBlock(c)) } // unclosed fence: still code
        return blocks
    }

    private static func isRule(_ l: String) -> Bool {
        let s = l.filter { !$0.isWhitespace }
        return s.count >= 3 && (s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" })
    }
    private static func bulletBody(_ l: String) -> String? {
        for p in ["- ", "* ", "• ", "+ "] where l.hasPrefix(p) { return String(l.dropFirst(2)) }
        let digits = l.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = l.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return String(rest.dropFirst(2)) }
        }
        return nil
    }
    private static func headingBody(_ l: String) -> String? {
        let hashes = l.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count), l.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
        return String(l.dropFirst(hashes.count + 1))
    }

    /// Bold (** or __), inline code, links (label kept, url dropped), images (alt kept). An unmatched marker is dropped, not shown.
    static func inline(_ s: String) -> [Run] {
        let c = Array(s)
        var runs: [Run] = []
        var buf = ""
        func text() { if !buf.isEmpty { runs.append(.text(buf)); buf = "" } }
        func find(_ m: [Character], from: Int) -> Int? {
            var j = from
            while j + m.count <= c.count { if Array(c[j..<j + m.count]) == m { return j }; j += 1 }
            return nil
        }
        func isWord(_ k: Int) -> Bool { k >= 0 && k < c.count && (c[k].isLetter || c[k].isNumber) }
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "`" {
                if let e = find(["`"], from: i + 1) {
                    text()
                    let t = String(c[(i + 1)..<e]).trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { runs.append(.code(t)) }
                    i = e + 1
                } else { i += 1 }
                continue
            }
            if (ch == "*" || ch == "_"), i + 1 < c.count, c[i + 1] == ch {
                if let e = find([ch, ch], from: i + 2), e > i + 2 {
                    text()
                    let t = inline(String(c[(i + 2)..<e])).map(\.string).joined()
                    if !t.isEmpty { runs.append(.bold(t)) }
                    i = e + 2
                } else { i += 2 }
                continue
            }
            if ch == "!" || ch == "[" {
                let start = ch == "!" ? i + 1 : i
                if start < c.count, c[start] == "[", let close = find(["]", "("], from: start + 1), let end = find([")"], from: close + 2) {
                    buf += inline(String(c[(start + 1)..<close])).map(\.string).joined()
                    i = end + 1
                } else { buf.append(ch); i += 1 }
                continue
            }
            if ch == "*" || ch == "_" {
                // Single emphasis marker: dropped only when it opens or closes a word (snake_case and 2*3 stay).
                let inside = isWord(i - 1) && isWord(i + 1)
                let edge = (isWord(i + 1) && !isWord(i - 1)) || (isWord(i - 1) && !isWord(i + 1))
                if !inside && edge { i += 1; continue }
            }
            buf.append(ch); i += 1
        }
        text()
        return runs
    }
}
