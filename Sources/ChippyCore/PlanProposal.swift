import Foundation

/// #91: the plan Claude proposes through ExitPlanMode. Shape taken from the Claude Code hooks docs
/// (`tool_input.plan` Markdown, `tool_input.planFilePath`), NOT yet from a live capture (docs/decisions/v1.3-payload-spikes.md).
/// The plan text may hold project detail (PDPA): keep it in memory only, never log it.
public struct PlanProposal: Equatable {
    public static let maxChars = 2000
    /// Rows the card shows folded and expanded; the rest is summarised as "N more lines".
    public static let collapsedLines = 5, expandedLines = 16
    /// Raw plan text beyond this is never looked at (bounds work on a hostile or huge payload).
    static let scanChars = 20_000

    /// Cleaned, capped plan text (hidden scalars stripped, newlines collapsed to spaces).
    public let text: String
    public let truncated: Bool
    /// Only the file name of planFilePath, never the full path.
    public let fileName: String?
    /// First Markdown heading when the plan opens with one (cleaned, "#" stripped).
    public let title: String?
    /// Cleaned non-empty body lines (title line excluded), within the same `maxChars` budget as `text`.
    public let lines: [String]
    /// Lines that are numbered or bulleted items.
    public let stepCount: Int
    /// Hidden or bidi scalars that were removed; the card says so rather than hiding the fact.
    public let hiddenRemoved: Int

    /// nil when this is not ExitPlanMode or the plan is missing, empty or not a string: the card then stays generic.
    public static func make(tool: String, input: [String: Any]) -> PlanProposal? {
        guard tool == "ExitPlanMode", let full = input["plan"] as? String else { return nil }
        let raw = String(full.prefix(scanChars))
        let cleaned = ApprovalIntent.clean(raw)
        guard !cleaned.isEmpty else { return nil }
        let over = cleaned.count > maxChars || full.count > scanChars
        let name = (input["planFilePath"] as? String)
            .map { ApprovalIntent.clean(($0 as NSString).lastPathComponent) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let separators: Set<Unicode.Scalar> = ["\n", "\r", "\t", "\u{2028}", "\u{2029}"]
        let hidden = raw.unicodeScalars.filter { ApprovalIntent.isHidden($0) && !separators.contains($0) }.count

        var rows = raw.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline || $0 == "\u{2028}" || $0 == "\u{2029}" })
            .map { ApprovalIntent.clean(String($0)) }.filter { !$0.isEmpty }
        var title: String?
        if let first = rows.first, first.hasPrefix("#") {
            let t = String(first.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { title = t; rows.removeFirst() }
        }
        var budget = maxChars - (title?.count ?? 0), body: [String] = []
        for r in rows where budget > 0 {
            body.append(String(r.prefix(budget))); budget -= r.count
        }
        let steps = body.filter(isStep).count
        return PlanProposal(text: over ? String(cleaned.prefix(maxChars)) : cleaned, truncated: over, fileName: name,
                            title: title, lines: body, stepCount: steps, hiddenRemoved: hidden)
    }

    static func isStep(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// The lines the card shows, and how many it leaves out (these plus the cap on `text` are the only omissions, and the card says so).
    public func visible(expanded: Bool) -> (shown: [String], hidden: Int) {
        let n = expanded ? Self.expandedLines : Self.collapsedLines
        return (Array(lines.prefix(n)), max(lines.count - n, 0))
    }

    public var canExpand: Bool { lines.count > Self.collapsedLines || truncated }
}
