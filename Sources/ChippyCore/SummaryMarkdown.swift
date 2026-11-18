import Foundation

/// Light markdown for the finished-card summary (#98b). Pure and on-device; nothing is logged or sent (PDPA).
/// Conservative: when unsure, text stays literal. Supports bold (** or __, only with a closer in the same paragraph),
/// inline code, bullets, headings (as bold lines), fenced code, and links (rendered "label (url)"). Unmatched ** and `
/// stay literal. Italics are not rendered: single * and _ always stay literal (globs, _app.tsx, char*).
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
        case heading([Run])
        case bullet([Run])
        case ordered(Int, [Run])
        case code(String)

        /// The block's text with no styling, for tests and accessibility.
        public var plain: String {
            switch self {
            case .paragraph(let r), .heading(let r), .bullet(let r), .ordered(_, let r): return r.map(\.string).joined()
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

    private static let cache: NSCache<NSString, DocBox> = {
        let c = NSCache<NSString, DocBox>(); c.countLimit = 16; return c
    }()
    private final class DocBox { let doc: Doc?; init(_ d: Doc?) { doc = d } }

    /// Parsed docs for the last 16 replies, in memory only (never persisted), so a re-created view reuses the parse.
    public static func doc(_ reply: String?) -> Doc? {
        guard let reply else { return nil }
        let key = reply as NSString
        if let hit = cache.object(forKey: key) { return hit.doc }
        let d = build(reply)
        cache.setObject(DocBox(d), forKey: key)
        return d
    }

    private static func textRuns(_ b: Block) -> [Run]? {
        switch b {
        case .paragraph(let r), .bullet(let r), .ordered(_, let r): return r
        case .heading, .code: return nil
        }
    }

    /// Outcome = the first non-heading text block, cut at its first sentence (else a word boundary) when long; the
    /// remainder follows in the details. Headings stay in the details.
    static func build(_ reply: String?) -> Doc? {
        var blocks = parse(reply)
        guard !blocks.isEmpty else { return nil }
        if let idx = blocks.firstIndex(where: { textRuns($0) != nil }) {
            let b = blocks.remove(at: idx)
            let (head, tail) = splitOutcome(textRuns(b) ?? [])
            if let tail { blocks.insert(.paragraph(tail), at: idx) } // plain: no repeated bullet or number
            return Doc(outcome: head, details: blocks)
        }
        // No prose: the outcome is the first code line (clipped). Code the outcome already shows is not repeated.
        if let ci = blocks.firstIndex(where: { if case .code = $0 { return true }; return false }), case .code(let c) = blocks[ci] {
            let lines = c.components(separatedBy: "\n")
            if let k = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let line = lines[k].trimmingCharacters(in: .whitespaces)
                let clipped = line.count > maxOutcome
                if !clipped {
                    let rest = lines[(k + 1)...].joined(separator: "\n")
                    if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.remove(at: ci) }
                    else { blocks[ci] = .code(rest) }
                }
                return Doc(outcome: [.code(clipped ? String(line.prefix(maxOutcome)) + "…" : line)], details: blocks)
            }
        }
        // Headings only: the first one is the outcome.
        if case .heading(let r) = blocks[0] { blocks.removeFirst(); return Doc(outcome: r, details: blocks) }
        return nil
    }

    private static let abbreviations: Set<String> = ["e.g", "i.e", "vs", "etc", "approx", "cf", "incl", "dr", "mr", "mrs", "ms", "no", "fig", "a.m", "p.m"]

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
        if cut == nil, chars.count > maxOutcome {
            // No sentence end: back up to a word boundary; the remainder starts there.
            var w = maxOutcome
            while w > 0, !chars[w].isWhitespace { w -= 1 }
            cut = w > 0 ? w : maxOutcome
            ellipsis = true
        }
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
        head = trimTrailing(head)
        if ellipsis { head.append(.text("…")) }
        tail = trimLeading(tail)
        return (head, tail.isEmpty ? nil : tail)
    }

    private static func trimTrailing(_ runs: [Run]) -> [Run] {
        var out = runs
        while let l = out.last {
            var t = l.string
            while let ch = t.last, ch.isWhitespace { t.removeLast() }
            if t.isEmpty { out.removeLast() } else { out[out.count - 1] = l.with(t); break }
        }
        return out
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
        var fence: (ch: Character, len: Int) = ("`", 3)
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
            if let c = code {
                if isFenceClose(line, fence.ch, fence.len) { appendCode(c); code = nil } else { code?.append(raw) }
                continue
            }
            if let f = fenceOpen(line) { flush(); fence = f; code = []; continue }
            if line.isEmpty || isRule(line) { flush(); continue }
            if let (num, b) = bulletBody(line) {
                flush()
                let runs = inline(b)
                if !runs.isEmpty { blocks.append(num.map { .ordered($0, runs) } ?? .bullet(runs)) }
            } else if let h = headingBody(line) {
                flush()
                let t = inline(h).map(\.string).joined()
                if !t.isEmpty { blocks.append(.heading([.bold(t)])) }
            } else {
                para.append(line.hasPrefix(">") ? String(line.drop(while: { $0 == ">" || $0 == " " })) : line)
            }
        }
        flush()
        if let c = code { appendCode(c) } // unclosed fence: still code
        return blocks
    }

    /// A line opens a fence only when it starts with ``` or ~~~ and does not close it on the same line
    /// ("```npm test``` passes" is inline text).
    private static func fenceOpen(_ line: String) -> (ch: Character, len: Int)? {
        guard let ch = line.first, ch == "`" || ch == "~" else { return nil }
        let len = line.prefix(while: { $0 == ch }).count
        guard len >= 3 else { return nil }
        if line.dropFirst(len).contains(String(repeating: ch, count: len)) { return nil }
        return (ch, len)
    }
    /// Closes with the same char, at least as long, and nothing else on the line.
    private static func isFenceClose(_ line: String, _ ch: Character, _ len: Int) -> Bool {
        let n = line.prefix(while: { $0 == ch }).count
        return n >= len && line.dropFirst(n).allSatisfy(\.isWhitespace)
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

    /// Bold (** or __), inline code, links ("label (url)"), images (alt kept). Unmatched ** and ` stay literal, as do
    /// single * and _ and runs of three or more markers. `__` bolds only at word boundaries, so __init__ and FOO__BAR stay literal.
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
        // Identifier-like = all-lowercase word characters (__init__); __Important__ is not.
        func isIdentifier(_ t: String) -> Bool { !t.isEmpty && t.allSatisfy { ($0.isLetter && !$0.isUppercase) || $0.isNumber || $0 == "_" } }
        // The ")" matching an already-open "(": inner balanced pairs (Foo_(bar)) are skipped. Bounded scan.
        func closingParen(from: Int) -> Int? {
            var depth = 0, k = from
            while k < c.count, k < from + 2048 {
                if c[k] == "(" { depth += 1 }
                else if c[k] == ")" { if depth == 0 { return k }; depth -= 1 }
                k += 1
            }
            return nil
        }
        // "[label](url)" starting at the "[" at `start`. "](" must follow with no "[" or "]" in between.
        func link(from start: Int) -> (String, String, Int)? {
            var j = start + 1
            while j < c.count, c[j] != "[", c[j] != "]" { j += 1 }
            guard j + 1 < c.count, c[j] == "]", c[j + 1] == "(", let end = closingParen(from: j + 2) else { return nil }
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
                } else { buf.append(ch); i += 1 }
                continue
            }
            if (ch == "*" || ch == "_"), i + 1 < c.count, c[i + 1] == ch {
                // Exactly two markers make bold; a longer run (***) stays literal.
                var n = 2
                while i + n < c.count, c[i + n] == ch { n += 1 }
                if n != 2 { buf += String(repeating: ch, count: n); i += n; continue }
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
                } else { buf += "**"; i += 2 }
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
            buf.append(ch); i += 1
        }
        text()
        return runs
    }
}
