import Foundation

/// Decides what `Chippy --render-* out.png` asks for (#223). Any argument that starts with `--render-` but is not a known
/// flag, or a known flag with no output path, is an error, so a typo exits instead of launching the full app.
public enum RenderFlag {
    public static let prefix = "--render-"

    public static let known = [
        "--render-gallery", "--render-done-detail", "--render-question", "--render-terminal-chip",
        "--render-approval", "--render-plan", "--render-tab", "--render-away", "--render-resting",
        "--render-waiting", "--render-needs-finished", "--render-finished-overflow", "--render-badge-dot",
        "--render-identity", "--render-glance", "--render-panel", "--render-mixed-header",
    ]

    public enum Result: Equatable {
        /// No `--render-*` argument: launch the app.
        case none
        /// Render `flag` to `output`.
        case render(flag: String, output: String)
        /// An argument starting `--render-` that is not a known flag.
        case unknown(String)
        /// A known flag with no output path after it.
        case missingOutput(String)
    }

    /// `args` is `CommandLine.arguments` (the first element, the binary path, is skipped).
    public static func parse(_ args: [String]) -> Result {
        let rest = Array(args.dropFirst())
        guard let i = rest.firstIndex(where: { $0.hasPrefix(prefix) }) else { return .none }
        let flag = rest[i]
        guard known.contains(flag) else { return .unknown(flag) }
        guard i + 1 < rest.count else { return .missingOutput(flag) }
        return .render(flag: flag, output: rest[i + 1])
    }

    /// The stderr text for an error result.
    public static func usage(_ result: Result) -> String {
        let head: String
        switch result {
        case .unknown(let f): head = "Unknown render flag: \(f)"
        case .missingOutput(let f): head = "\(f) needs an output path, e.g. \(f) out.png"
        default: head = "Render flags"
        }
        return head + "\nValid flags (each takes an output path):\n" + known.map { "  \($0)" }.joined(separator: "\n") + "\n"
    }
}
