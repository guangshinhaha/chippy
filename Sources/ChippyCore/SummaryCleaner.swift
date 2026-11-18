import Foundation

/// On-device text cleanup for the finished/question cards (#98a). Pure; nothing is logged or sent anywhere (PDPA).
public enum SummaryCleaner {
    /// Longest input looked at, so a huge or adversarial string cannot make the regex passes slow.
    static let maxInput = 4000
    public static let maxDecisionChars = 200

    /// System markup Claude Code injects into the "prompt": the block AND its content go.
    static let systemTags = ["task-notification", "system-reminder", "command-name", "command-message", "command-args",
                             "local-command-stdout", "local-command-stderr", "local-command-caveat", "user-prompt-submit-hook"]
    /// Tags that only ever appear as system markup (children of the blocks above). Only these are stripped when stray,
    /// so `<my-component>` in a real prompt stays.
    static let strayTags = systemTags + ["task-id", "tool-use-id", "output-file"]

    private static func alternation(_ names: [String]) -> String {
        names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    }
    private static let blockRe = try? NSRegularExpression(
        pattern: "<(\(alternation(systemTags)))(?:\\s[^>]*)?>[\\s\\S]*?</\\1\\s*>", options: [.caseInsensitive])
    /// An opening system tag left after the closed blocks went: nothing closes it, so it and everything after is dropped.
    private static let unclosedRe = try? NSRegularExpression(
        pattern: "<(?:\(alternation(systemTags)))(?:\\s[^>]*)?>", options: [.caseInsensitive])
    private static let strayRe = try? NSRegularExpression(
        pattern: "</?(?:\(alternation(strayTags)))(?:\\s[^>]*)?/?>", options: [.caseInsensitive])

    /// The prompt without system-notification markup, whitespace collapsed; nil when nothing readable remains.
    public static func cleanPrompt(_ raw: String?) -> String? {
        guard var s = raw.map({ String($0.prefix(maxInput)) }) else { return nil }
        for _ in 0..<5 { // nested blocks: peel until stable
            let before = s
            s = replace(blockRe, in: s)
            if s == before { break }
        }
        if let m = unclosedRe?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) {
            s = String(s[..<r.lowerBound])
        }
        s = replace(strayRe, in: s)
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    private static func replace(_ re: NSRegularExpression?, in s: String) -> String {
        guard let re else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    private static let junk = CharacterSet(charactersIn: "*_`~>)]\"'\u{201D} ").union(.whitespacesAndNewlines)
    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "cf", "approx", "no", "mr", "mrs", "ms", "dr", "st", "fig", "eg", "ie"]

    /// A "." after an abbreviation or a bare number/version ("e.g.", "v2.", "3.") does not end a sentence.
    private static func endsSentence(_ chars: [Character], at i: Int) -> Bool {
        guard i + 1 < chars.count, chars[i + 1].isWhitespace else { return false }
        guard chars[i] == "." else { return true }
        var j = i - 1
        while j >= 0, !chars[j].isWhitespace { j -= 1 }
        let tok = String(chars[(j + 1)..<i]).trimmingCharacters(in: CharacterSet(charactersIn: "(*_\"'`")).lowercased()
        if abbreviations.contains(tok) { return false }
        if tok.range(of: "^v?\\d+(\\.\\d+)*$", options: .regularExpression) != nil { return false }
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

    /// The closing question of a final message (its last sentence, when the message ends on "?"), markdown markers
    /// dropped and capped, plus the reply without that sentence. decision is nil when there is no usable question.
    public static func splitDecision(_ reply: String?) -> (decision: String?, rest: String) {
        guard let (full, body, trailing) = questionBody(reply) else { return (nil, reply ?? "") }
        let chars = Array(String(body.suffix(maxInput)))
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
        // Everything from the sentence start to the end of the text (trailing markdown included) is the decision.
        let rest = String(full.dropLast((chars.count - start) + trailing)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (TranscriptTail.truncate(q + "?", to: maxDecisionChars), rest)
    }

    public static func closingDecision(_ reply: String?) -> String? { splitDecision(reply).decision }
}
