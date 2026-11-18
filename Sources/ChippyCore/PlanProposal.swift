import Foundation

/// #91: the plan Claude proposes through ExitPlanMode. Shape taken from the Claude Code hooks docs
/// (`tool_input.plan` Markdown, `tool_input.planFilePath`), NOT yet from a live capture (docs/decisions/v1.3-payload-spikes.md).
/// The plan text may hold project detail (PDPA): keep it in memory only, never log it.
public struct PlanProposal: Equatable {
    public static let maxChars = 2000
    /// Rows the card shows folded and expanded; the rest is summarised.
    public static let collapsedLines = 5, expandedLines = 16
    /// Raw plan text beyond this is never looked at (bounds work on a hostile or huge payload).
    static let scanChars = 20_000

    /// True when anything of the plan is not readable in the card even expanded: dropped rows (char budget, scan cap,
    /// row limit) or a row clipped to `rowChars`. The card then says "continues in the terminal" and labels Approve "partly shown".
    public let truncated: Bool
    /// Only the file name of planFilePath, never the full path.
    public let fileName: String?
    /// First Markdown heading ("# " then text) when the plan opens with one (cleaned, clipped).
    public let title: String?
    /// Cleaned non-empty body lines (title line excluded), each at most `rowChars`, within the `maxChars` budget.
    public let lines: [String]
    /// Lines that are numbered or bulleted items, counted over the whole scanned plan (not only the displayed ones).
    public let stepCount: Int
    /// Hidden or bidi scalars removed from the rows actually displayed; the card says so rather than hiding the fact.
    public let hiddenRemoved: Int

    /// A row longer than this is clipped (the card shows two lines per row), and counts as truncated.
    public static let rowChars = 140

    /// nil when this is not ExitPlanMode or the plan is missing, empty or not a string: the caller then falls back to the terminal.
    public static func make(tool: String, input: [String: Any]) -> PlanProposal? {
        guard tool == "ExitPlanMode", let full = input["plan"] as? String else { return nil }
        let prefix = full.prefix(scanChars + 1) // bounded: never counts or walks a huge payload
        var truncated = prefix.count > scanChars
        let raw = String(prefix.prefix(scanChars))
        let name = (input["planFilePath"] as? String)
            .map { ApprovalIntent.clean(($0 as NSString).lastPathComponent) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Character.isNewline covers \n \r VT FF NEL LS PS; the two Unicode separators are listed for clarity.
        var rows: [(raw: Substring, text: String)] = raw.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
            .map { ($0, ApprovalIntent.clean(String($0))) }.filter { !$0.text.isEmpty }
        guard !rows.isEmpty else { return nil }
        let steps = rows.filter { isStep($0.text) }.count
        var hidden = 0
        func countHidden(_ r: Substring) {
            hidden += r.unicodeScalars.filter { ApprovalIntent.isHidden($0) && $0 != "\t" }.count
        }
        var title: String?
        var budget = maxChars
        if let first = rows.first, case let hashes = first.text.prefix(while: { $0 == "#" }),
           (1...6).contains(hashes.count), first.text.dropFirst(hashes.count).hasPrefix(" ") { // "#!/bin", "#1", "#tag" are not headings
            let t = first.text.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                let clipped = String(t.prefix(min(rowChars, budget)))
                if clipped.count < t.count { truncated = true }
                title = clipped; budget -= clipped.count; countHidden(first.raw); rows.removeFirst()
            }
        }
        var body: [String] = []
        for r in rows {
            if budget <= 0 || body.count >= expandedLines { truncated = true; break }
            let clipped = String(r.text.prefix(min(rowChars, budget)))
            if clipped.count < r.text.count { truncated = true }
            body.append(clipped); budget -= clipped.count; countHidden(r.raw)
        }
        return PlanProposal(truncated: truncated, fileName: name, title: title, lines: body, stepCount: steps, hiddenRemoved: hidden)
    }

    static func isStep(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        let digits = line.prefix(while: { $0 >= "0" && $0 <= "9" })
        guard !digits.isEmpty, digits.count <= 3 else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// The lines the card shows, and how many it leaves out of the stored lines.
    public func visible(expanded: Bool) -> (shown: [String], hidden: Int) {
        let n = expanded ? Self.expandedLines : Self.collapsedLines
        return (Array(lines.prefix(n)), max(lines.count - n, 0))
    }

    public var canExpand: Bool { lines.count > Self.collapsedLines || truncated }
}
