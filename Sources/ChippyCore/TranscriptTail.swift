import Foundation

/// Reads Claude's lead-in (the text it said just before asking a question) from the tail of a session transcript.
/// Transcript format (checked against real files, structure only): JSONL, one content block per line, each line
/// `{"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}`; real user prompts are `type":"user"`
/// with string content or a text block; tool results are `user` lines with `tool_result` blocks.
/// Local read only. The result is never logged or written anywhere. Any failure returns nil (fail open).
public enum TranscriptTail {
    public static let tailBytes = 64 * 1024
    public static let maxChars = 600

    /// Last assistant text block, truncated, provided no tool result or user prompt came after it (so it really is what Claude said just before asking). nil if unreadable or none.
    public static func leadIn(path: String, tailBytes: Int = TranscriptTail.tailBytes, maxChars: Int = TranscriptTail.maxChars) -> String? {
        guard path.hasPrefix("/"), let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? fh.seek(toOffset: start)) != nil, let data = try? fh.readToEnd() else { return nil }
        return lastAssistantText(inTail: data, startsMidFile: start > 0, maxChars: maxChars)
    }

    /// Pure parser over the tail bytes. When the tail starts mid-file the first (partial) line is dropped.
    public static func lastAssistantText(inTail data: Data, startsMidFile: Bool = false, maxChars: Int = TranscriptTail.maxChars) -> String? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if startsMidFile, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = o["type"] as? String, o["isSidechain"] as? Bool != true,
                  let msg = o["message"] as? [String: Any] else { continue } // malformed or unrelated line
            if type == "user" {
                if msg["content"] is String { return nil } // a real prompt: nothing Claude said in this turn
                if let blocks = msg["content"] as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "text" }) { return nil }
                return nil // a tool_result: Claude has been working since it last spoke, so any earlier text is not a lead-in
            }
            guard type == "assistant" else { continue }
            if let s = msg["content"] as? String, let t = clean(s) { return truncate(t, to: maxChars) }
            if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks.reversed() where b["type"] as? String == "text" {
                    if let t = (b["text"] as? String).flatMap(clean) { return truncate(t, to: maxChars) }
                }
            }
        }
        return nil
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// At most `n` characters, with an ellipsis (counted inside the limit) when cut.
    public static func truncate(_ s: String, to n: Int) -> String {
        guard s.count > n, n > 0 else { return s }
        return String(s.prefix(n - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
