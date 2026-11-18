import Foundation

/// Spike for #91: the plan Claude proposes through ExitPlanMode. Shape taken from the Claude Code hooks docs
/// (`tool_input.plan` Markdown, `tool_input.planFilePath`), NOT yet from a live capture. Not wired into any UI.
/// The plan text may hold project detail (PDPA): keep it in memory only, never log it.
public struct PlanProposal: Equatable {
    public static let maxChars = 2000
    /// Cleaned, capped plan text (hidden scalars stripped, newlines collapsed to spaces for the compact view).
    public let text: String
    public let truncated: Bool
    /// Only the file name of planFilePath, never the full path.
    public let fileName: String?

    /// nil when this is not ExitPlanMode or the plan is missing, empty or not a string: the card then stays generic.
    public static func make(tool: String, input: [String: Any]) -> PlanProposal? {
        guard tool == "ExitPlanMode", let raw = input["plan"] as? String else { return nil }
        let cleaned = ApprovalIntent.clean(raw)
        guard !cleaned.isEmpty else { return nil }
        let over = cleaned.count > maxChars
        let name = (input["planFilePath"] as? String)
            .map { ApprovalIntent.clean(($0 as NSString).lastPathComponent) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return PlanProposal(text: over ? String(cleaned.prefix(maxChars)) : cleaned, truncated: over, fileName: name)
    }
}
