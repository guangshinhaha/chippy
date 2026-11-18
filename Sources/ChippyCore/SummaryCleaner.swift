import Foundation

/// On-device text cleanup for the finished/question cards (#98a). Pure; nothing is logged or sent anywhere (PDPA).
public enum SummaryCleaner {
    /// Longest input looked at, so a huge or adversarial string cannot make the regex passes slow.
    static let maxInput = 4000
    public static let maxDecisionChars = 200

    /// System markup Claude Code injects into the "prompt": the block AND its content go.
    static let systemTags = ["task-notification", "system-reminder", "command-name", "command-message", "command-args",
                             "local-command-stdout", "local-command-stderr", "local-command-caveat", "user-prompt-submit-hook"]

    private static let blockRe: NSRegularExpression? = {
        let names = systemTags.joined(separator: "|")
        return try? NSRegularExpression(pattern: "<(\(names))(?:\\s[^>]*)?>[\\s\\S]*?</\\1\\s*>", options: [.caseInsensitive])
    }()
    /// Any leftover tag with a hyphenated name (`<task-id>`, `</task-id>`): markup, not prose. Plain `<div>` / `a < b` stay.
    private static let strayRe = try? NSRegularExpression(pattern: "</?[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+(?:\\s[^>]*)?/?>")

    /// The prompt without system-notification markup, whitespace collapsed; nil when nothing readable remains.
    public static func cleanPrompt(_ raw: String?) -> String? {
        guard var s = raw.map({ String($0.prefix(maxInput)) }) else { return nil }
        for _ in 0..<5 { // nested blocks: peel until stable
            let before = s
            s = replace(blockRe, in: s)
            if s == before { break }
        }
        s = replace(strayRe, in: s)
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    private static func replace(_ re: NSRegularExpression?, in s: String) -> String {
        guard let re else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    /// The closing question of a final message (its last sentence, when the message ends on "?"), markdown
    /// markers dropped, capped. nil when the message does not end on a question or the ending is code.
    public static func closingDecision(_ reply: String?) -> String? {
        guard let reply else { return nil }
        let text = String(reply.suffix(maxInput)).trimmingCharacters(in: .whitespacesAndNewlines)
        // An unclosed code fence at the end means the tail is code, not a question to the user.
        if text.components(separatedBy: "```").count % 2 == 0 { return nil }
        let junk = CharacterSet(charactersIn: "*_`~>)]\"'” ").union(.whitespacesAndNewlines)
        var body = text.trimmingCharacters(in: junk)
        guard body.hasSuffix("?") else { return nil }
        body.removeLast()
        // Walk back to the start of the final sentence.
        let chars = Array(body)
        var start = 0
        var i = chars.count - 1
        while i >= 0 {
            let c = chars[i]
            if c.isNewline { start = i + 1; break }
            if ".!?".contains(c), i + 1 < chars.count, chars[i + 1].isWhitespace { start = i + 1; break }
            i -= 1
        }
        var q = String(chars[start...])
        q = q.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*_ ").union(.whitespacesAndNewlines))
        q = q.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard q.count >= 3, !q.contains("://") else { return nil }
        return TranscriptTail.truncate(q + "?", to: maxDecisionChars)
    }
}
