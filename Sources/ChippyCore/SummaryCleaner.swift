import Foundation

/// On-device text cleanup for the finished/question cards (#98a). Pure; nothing is logged or sent anywhere (PDPA).
public enum SummaryCleaner {
    /// Longest input looked at, so a huge or adversarial string cannot make the regex passes slow.
    static let maxInput = 100_000
    static let maxSentenceScan = 4000
    public static let maxDecisionChars = 200

    /// System markup Claude Code injects into the "prompt": the block AND its content go.
    static let systemTags = ["task-notification", "system-reminder",
                             "local-command-stdout", "local-command-stderr", "local-command-caveat", "user-prompt-submit-hook"]
    /// Tags that only ever appear as system markup (children of the blocks above). Only these are stripped when stray,
    /// so `<my-component>` in a real prompt stays.
    static let strayTags = systemTags + ["command-name", "command-message", "command-args", "task-id", "tool-use-id", "output-file"]

    private static func alternation(_ names: [String]) -> String {
        names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    }
    /// An opening system tag (with optional attributes).
    private static let openRe = try? NSRegularExpression(
        pattern: "<(\(alternation(systemTags)))(?:\\s[^>]*)?>", options: [.caseInsensitive])
    private static let strayRe = try? NSRegularExpression(
        pattern: "</?(?:\(alternation(strayTags)))(?:\\s[^>]*)?/?>", options: [.caseInsensitive])
    private static let closeTail = try? NSRegularExpression(pattern: "^\\s*>")

    /// Removes each system block with its content in one linear pass. An opening tag nothing closes drops itself and
    /// everything after it (a regex with a lazy body would rescan to the end for every unclosed tag: quadratic).
    private static func stripBlocks(_ s: String) -> String {
        guard let openRe else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        var from = 0
        while from < ns.length,
              let m = openRe.firstMatch(in: s, range: NSRange(location: from, length: ns.length - from)) {
            let name = ns.substring(with: m.range(at: 1))
            let closer = "</" + name
            var search = m.range.location + m.range.length
            var end: Int? = nil
            while search < ns.length {
                let r = ns.range(of: closer, options: [.caseInsensitive], range: NSRange(location: search, length: ns.length - search))
                if r.location == NSNotFound { break }
                let tailStart = r.location + r.length
                let tail = ns.substring(with: NSRange(location: tailStart, length: min(ns.length - tailStart, 64)))
                if let t = closeTail?.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) {
                    end = tailStart + t.range.length; break
                }
                search = tailStart
            }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)) + " "
            guard let end else { return out } // unclosed: the rest goes
            cursor = end; from = end
        }
        return out + ns.substring(from: cursor)
    }

    private static func firstCapture(_ tag: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<\\(tag)>(.*?)</\\(tag)>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// A slash command arrives as <command-name>/x</command-name><command-message>..</command-message><command-args>..</command-args>.
    /// What the user typed is "/x args": rewrite the wrappers to that text (the message block only repeats the name).
    private static func foldSlashCommand(_ s: String) -> String {
        guard let rawName = firstCapture("command-name", in: s) else { return s }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return s }
        let args = (firstCapture("command-args", in: s) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var out = s
        for tag in ["command-message", "command-args", "command-name"] {
            guard let re = try? NSRegularExpression(pattern: "<\\(tag)>.*?</\\(tag)>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let tpl = tag == "command-name" ? NSRegularExpression.escapedTemplate(for: " " + (name.hasPrefix("/") ? name : "/" + name) + (args.isEmpty ? "" : " " + args) + " ") : " "
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: tpl)
        }
        return out
    }

    /// The prompt without system-notification markup, whitespace collapsed; nil when nothing readable remains.
    /// Cleans the whole text (bounded at maxInput for speed); callers cap the RESULT.
    public static func cleanPrompt(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var s = stripBlocks(foldSlashCommand(String(raw.prefix(maxInput))))
        s = replace(strayRe, in: s)
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    private static func replace(_ re: NSRegularExpression?, in s: String) -> String {
        guard let re else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    private static let junk = CharacterSet(charactersIn: "*_`~>)]\"'\u{201D} ").union(.whitespacesAndNewlines)
    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "cf", "approx", "mr", "mrs", "ms", "dr", "st", "fig", "eg", "ie"]

    /// A "." after an abbreviation ("e.g.", "etc.", "Mr.") does not end a sentence.
    private static func endsSentence(_ chars: [Character], at i: Int) -> Bool {
        guard i + 1 < chars.count, chars[i + 1].isWhitespace else { return false }
        guard chars[i] == "." else { return true }
        var j = i - 1
        while j >= 0, !chars[j].isWhitespace { j -= 1 }
        let tok = String(chars[(j + 1)..<i]).trimmingCharacters(in: CharacterSet(charactersIn: "(*_\"'`")).lowercased()
        if abbreviations.contains(tok) { return false }
        return true
    }

    /// The one test for "this message ends on a question to the user": the whole trimmed text, and that text without
    /// trailing markdown/brackets/quotes and without its final "?"; nil otherwise. Fence parity is taken over the WHOLE
    /// text (an unclosed fence means the tail is code).
    static func questionBody(_ reply: String?) -> (full: String, body: String, trailing: Int)? {
        guard let reply else { return nil }
        let full = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.components(separatedBy: "```").count % 2 == 0 { return nil }
        var body = Substring(full)
        while let l = body.last, l.unicodeScalars.allSatisfy(junk.contains) { body = body.dropLast() }
        guard body.last == "?" else { return nil }
        body = body.dropLast()
        return (full, String(body), full.count - body.count)
    }

    /// True when the message ends on a question (shared by "waiting for your reply" and the decision line).
    public static func endsOnQuestion(_ reply: String?) -> Bool { questionBody(reply) != nil }

    /// asksYou, the closing question and the reply body, all from ONE questionBody call.
    public static func analyze(_ reply: String?) -> (asksYou: Bool, decision: String?, rest: String) {
        guard let qb = questionBody(reply) else { return (false, nil, reply ?? "") }
        let s = split(qb)
        return (true, s.decision, s.rest)
    }

    public static func splitDecision(_ reply: String?) -> (decision: String?, rest: String) {
        let a = analyze(reply); return (a.decision, a.rest)
    }

    /// The closing question of a final message (its last sentence, when the message ends on "?"), markdown markers
    /// dropped and capped. rest is the reply without that sentence, but only when the sentence is shown whole: a
    /// truncated decision leaves the full sentence in the body.
    private static func split(_ qb: (full: String, body: String, trailing: Int)) -> (decision: String?, rest: String) {
        let (full, body, trailing) = qb
        let chars = Array(String(body.suffix(maxSentenceScan)))
        var start = 0
        var i = chars.count - 1
        while i >= 0 {
            if chars[i].isNewline { start = i + 1; break }
            if ".!?".contains(chars[i]), endsSentence(chars, at: i) { start = i + 1; break }
            i -= 1
        }
        var q = String(chars[start...])
        q = q.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*_( ").union(.whitespacesAndNewlines))
        q = q.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard q.count >= 3, !q.contains("://") else { return (nil, full) }
        let shown = TranscriptTail.truncate(q + "?", to: maxDecisionChars)
        if (q + "?").count > maxDecisionChars { return (shown, full) }
        let rest = String(full.dropLast((chars.count - start) + trailing)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (shown, rest)
    }

    public static func closingDecision(_ reply: String?) -> String? { splitDecision(reply).decision }
}
