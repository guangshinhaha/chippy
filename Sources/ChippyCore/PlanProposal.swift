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
    /// Hidden or bidi scalars removed, per displayed row (the first `rowChars` characters of each body row) and for the title.
    let titleHidden: Int
    let rowHidden: [Int]

    /// Hidden or bidi scalars removed from what the card shows (title plus the rows of this view); the card says so rather than hiding the fact.
    public func hiddenRemoved(expanded: Bool) -> Int {
        titleHidden + rowHidden.prefix(expanded ? Self.expandedLines : Self.collapsedLines).reduce(0, +)
    }

    /// A row longer than this is clipped (the card shows two lines per row), and counts as truncated.
    public static let rowChars = 140

    /// nil when this is not ExitPlanMode or the plan is missing, empty or not a string: the caller then falls back to the terminal.
    public static func make(tool: String, input: [String: Any]) -> PlanProposal? {
        guard tool == "ExitPlanMode", let full = input["plan"] as? String else { return nil }
        let prefix = full.prefix(scanChars + 1) // bounded: never counts or walks a huge payload
        var truncated = prefix.count > scanChars
        let raw = String(prefix.prefix(scanChars))
        let name = (input["planFilePath"] as? String)
            .map { cleanText(($0 as NSString).lastPathComponent) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Character.isNewline covers \n \r VT FF NEL LS PS; the two Unicode separators are listed for clarity.
        var rows: [(raw: Substring, text: String)] = raw.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline })
            .map { ($0, cleanText(String($0))) }.filter { !$0.text.isEmpty }
        guard !rows.isEmpty else { return nil }
        let steps = rows.filter { isStep($0.text) }.count
        func countHidden(_ r: Substring) -> Int { Self.countHidden(raw: r) }
        var titleHidden = 0
        var rowHidden: [Int] = []
        var title: String?
        var budget = maxChars
        if let first = rows.first, case let hashes = first.text.prefix(while: { $0 == "#" }),
           (1...6).contains(hashes.count), first.text.dropFirst(hashes.count).hasPrefix(" ") { // "#!/bin", "#1", "#tag" are not headings
            let t = first.text.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                let clipped = String(t.prefix(min(rowChars, budget)))
                if clipped.count < t.count { truncated = true }
                title = clipped; budget -= clipped.count; titleHidden = countHidden(first.raw); rows.removeFirst()
            }
        }
        var body: [String] = []
        for r in rows {
            if budget <= 0 || body.count >= expandedLines { truncated = true; break }
            let clipped = String(r.text.prefix(min(rowChars, budget)))
            if clipped.count < r.text.count { truncated = true }
            body.append(clipped); budget -= clipped.count; rowHidden.append(countHidden(r.raw))
        }
        return PlanProposal(truncated: truncated, fileName: name, title: title, lines: body, stepCount: steps, titleHidden: titleHidden, rowHidden: rowHidden)
    }

    /// ApprovalIntent.clean, then the card's own marker symbol is shown as `<U+22EF>` (as `reveal` does), so plan text can't forge "⋯ ... ⋯" rows.
    static func cleanText(_ s: String) -> String {
        ApprovalIntent.clean(s).replacingOccurrences(of: String(ApprovalIntent.markSymbol), with: "<U+22EF>")
    }

    /// Hidden scalars within what the card displays of a raw row: walks the raw row the way `clean` does (whitespace runs
    /// collapse, hidden scalars drop) and stops once `rowChars` cleaned characters are out.
    static func countHidden(raw: Substring) -> Int {
        let breaks: Set<UInt32> = [0x09, 0x0A, 0x0D, 0x2028, 0x2029]
        var emitted = 0, hidden = 0, pendingSpace = false
        for u in raw.unicodeScalars {
            if emitted >= rowChars { break }
            if u == " " || breaks.contains(u.value) { pendingSpace = emitted > 0; continue }
            if ApprovalIntent.isHidden(u) { hidden += 1; continue }
            if pendingSpace { emitted += 1; pendingSpace = false; if emitted >= rowChars { break } }
            emitted += u == ApprovalIntent.markSymbol ? 8 : 1
        }
        return hidden
    }

    static func isStep(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        let scalars = line.unicodeScalars // ASCII digits only: Character ordering would let "5\u{301}" through
        let digits = scalars.prefix(while: { (0x30...0x39).contains($0.value) }).count
        guard digits > 0, digits <= 3 else { return false }
        let rest = String(String.UnicodeScalarView(scalars.dropFirst(digits)))
        return rest.unicodeScalars.starts(with: ". ".unicodeScalars) || rest.unicodeScalars.starts(with: ") ".unicodeScalars)
    }

    /// The lines the card shows, and how many it leaves out of the stored lines.
    public func visible(expanded: Bool) -> (shown: [String], hidden: Int) {
        let n = expanded ? Self.expandedLines : Self.collapsedLines
        return (Array(lines.prefix(n)), max(lines.count - n, 0))
    }

    /// Only when there is something more to show: a short plan that is merely truncated has no no-op "Show more".
    public var canExpand: Bool { lines.count > Self.collapsedLines }
}
