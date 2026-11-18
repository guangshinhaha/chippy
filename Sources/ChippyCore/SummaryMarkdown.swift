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
        case ordered(Int, [Run])
        case code(String)

        /// The block's text with no styling, for tests and accessibility.
        public var plain: String {
            switch self {
            case .paragraph(let r), .bullet(let r), .ordered(_, let r): return r.map(\.string).joined()
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
        func runsOf(_ b: Block) -> [Run]? {
            switch b {
            case .paragraph(let r), .bullet(let r), .ordered(_, let r): return r
            case .code: return nil
            }
        }
        if let runs = runsOf(blocks[0]) {
            blocks.removeFirst()
            let (head, tail) = splitOutcome(runs)
            return Doc(outcome: head, details: (tail.map { [Block.paragraph($0)] } ?? []) + blocks)
        }
        // Reply opens with code: the outcome is the first text line after it, else the first code line (clipped).
        if let idx = blocks.firstIndex(where: { runsOf($0) != nil }), let runs = runsOf(blocks[idx]) {
            blocks.remove(at: idx)
            let (head, tail) = splitOutcome(runs)
            if let tail { blocks.insert(.paragraph(tail), at: idx) }
            return Doc(outcome: head, details: blocks)
        }
        let line = blocks.compactMap { b -> String? in
            if case .code(let c) = b { return c.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
            return nil
        }.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        let clipped = line.count > maxOutcome ? String(line.prefix(maxOutcome)) + "…" : line
        return Doc(outcome: [.code(clipped)], details: blocks)
    }

    private static let abbreviations: Set<String> = ["e.g", "i.e", "vs", "etc", "approx", "cf", "incl"]

    /// True when the "." at `i` ends an abbreviation or a version ("v2.") rather than a sentence.
    private static func isAbbreviationDot(_ chars: [Character], _ i: Int) -> Bool {
        var j = i
        while j > 0, !chars[j - 1].isWhitespace, chars[j - 1] != "(" { j -= 1 }
        let token = String(chars[j..<i]).lowercased()
        if abbreviations.contains(token) { return true }
        if token.hasPrefix("v"), token.count > 1, token.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
            var k = i + 1
            while k < chars.count, chars[k].isWhitespace { k += 1 }
            if k < chars.count, chars[k].isNumber || (chars[k].isLowercase) { return true }
        }
        return false
    }

    private static func splitOutcome(_ runs: [Run]) -> ([Run], [Run]?) {
        let plain = runs.map(\.string).joined()
        guard plain.count > maxOutcome / 2 else { return (runs, nil) }
        // First sentence end within the cap, found on the plain text, then mapped back onto the runs.
        let chars = Array(plain)
        var cut: Int? = nil
        var i = 8
        while i < min(chars.count - 1, maxOutcome) {
            if ".!?".contains(chars[i]), chars[i + 1].isWhitespace, !(chars[i] == "." && isAbbreviationDot(chars, i)) { cut = i + 1; break }
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
        func appendCode(_ c: [String]) {
            if c.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { blocks.append(codeBlock(c)) }
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
                if let c = code { appendCode(c); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty || isRule(line) { flush(); continue }
            if let (num, b) = bulletBody(line) {
                flush()
                let runs = inline(b)
                if !runs.isEmpty { blocks.append(num.map { .ordered($0, runs) } ?? .bullet(runs)) }
            } else if let h = headingBody(line) {
                flush()
                let t = inline(h).map(\.string).joined()
                if !t.isEmpty { blocks.append(.paragraph([.bold(t)])) }
            } else {
                para.append(line.hasPrefix(">") ? String(line.drop(while: { $0 == ">" || $0 == " " })) : line)
            }
        }
        flush()
        if let c = code { appendCode(c) } // unclosed fence: still code
        return blocks
    }

    private static func isRule(_ l: String) -> Bool {
        let s = l.filter { !$0.isWhitespace }
        return s.count >= 3 && (s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" })
    }
    /// (number, body): number is nil for a plain bullet.
    private static func bulletBody(_ l: String) -> (Int?, String)? {
        for p in ["- ", "* ", "• ", "+ "] where l.hasPrefix(p) { return (nil, String(l.dropFirst(2))) }
        let digits = l.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = l.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (Int(digits), String(rest.dropFirst(2))) }
        }
        return nil
    }
    private static func headingBody(_ l: String) -> String? {
        let hashes = l.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count), l.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
        return String(l.dropFirst(hashes.count + 1))
    }

    /// Bold (** or __), inline code, links ("label (url)"), images (alt kept). An unmatched ** or ` is dropped, not shown.
    /// `__` bolds only at word boundaries, so __init__ and FOO__BAR stay literal.
    static func inline(_ s: String) -> [Run] {
        let c = Array(s)
        var runs: [Run] = []
        var buf = ""
        func text() { if !buf.isEmpty { runs.append(.text(buf)); buf = "" } }
        // Index scan, no slicing. A failed search from x means every later search of the same kind fails too,
        // so unmatched markers cost O(n) in total.
        var noneFrom: [String: Int] = [:]
        func find(_ key: String, from: Int, _ match: (Int) -> Bool) -> Int? {
            if let n = noneFrom[key], from >= n { return nil }
            var j = from
            while j < c.count { if match(j) { return j }; j += 1 }
            noneFrom[key] = min(noneFrom[key] ?? Int.max, from)
            return nil
        }
        func findChar(_ ch: Character, from: Int) -> Int? { find(String(ch), from: from) { c[$0] == ch } }
        func isWord(_ k: Int) -> Bool { k >= 0 && k < c.count && (c[k].isLetter || c[k].isNumber) }
        func findPair(_ ch: Character, from: Int) -> Int? {
            if ch == "*" { return find("**", from: from) { $0 + 1 < c.count && c[$0] == "*" && c[$0 + 1] == "*" } }
            return find("__", from: from) { $0 + 1 < c.count && c[$0] == "_" && c[$0 + 1] == "_" && !c[$0 - 1 >= 0 ? $0 - 1 : 0].isWhitespace && !isWord($0 + 2) }
        }
        func isIdentifier(_ t: String) -> Bool { !t.isEmpty && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }
        // "[label](url)" starting at the "[" at `start`. "](" must follow with no "[" or "]" in between.
        func link(from start: Int) -> (String, String, Int)? {
            var j = start + 1
            while j < c.count, c[j] != "[", c[j] != "]" { j += 1 }
            guard j + 1 < c.count, c[j] == "]", c[j + 1] == "(", let end = findChar(")", from: j + 2) else { return nil }
            let raw = String(c[(j + 2)..<end]).trimmingCharacters(in: .whitespaces)
            let url = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            return (String(c[(start + 1)..<j]), url, end + 1)
        }
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "`" {
                if let e = findChar("`", from: i + 1) {
                    text()
                    let t = String(c[(i + 1)..<e]).trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { runs.append(.code(t)) }
                    i = e + 1
                } else { i += 1 }
                continue
            }
            if (ch == "*" || ch == "_"), i + 1 < c.count, c[i + 1] == ch {
                if ch == "_" {
                    // Opening __ must start a word; the closer is found by findPair (ends a word, no space before).
                    if !isWord(i - 1), i + 2 < c.count, !c[i + 2].isWhitespace, let e = findPair("_", from: i + 2), e > i + 2 {
                        let inner = String(c[(i + 2)..<e])
                        if !isIdentifier(inner) {
                            text()
                            let t = inline(inner).map(\.string).joined()
                            if !t.isEmpty { runs.append(.bold(t)) }
                            i = e + 2
                            continue
                        }
                    }
                    buf += "__"; i += 2
                } else if let e = findPair("*", from: i + 2), e > i + 2 {
                    text()
                    let t = inline(String(c[(i + 2)..<e])).map(\.string).joined()
                    if !t.isEmpty { runs.append(.bold(t)) }
                    i = e + 2
                } else { i += 2 }
                continue
            }
            if ch == "!" || ch == "[" {
                let start = ch == "!" ? i + 1 : i
                if start < c.count, c[start] == "[", let (label, url, next) = link(from: start) {
                    let l = inline(label).map(\.string).joined()
                    if ch == "!" || url.isEmpty { buf += l }
                    else if l.isEmpty || l == url { buf += url }
                    else { buf += "\(l) (\(url))" }
                    i = next
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
