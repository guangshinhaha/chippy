import Foundation

/// Orca host support (#65, #129). Pure: AppKit finds the running app and runs the process; this decides.
public enum OrcaCLI {
    public static let bundleId = "com.stablyai.orca"

    /// The CLI shipped inside the running app's bundle. Never a fixed install path.
    public static func cliURL(appBundleURL: URL?) -> URL? {
        appBundleURL?.appendingPathComponent("Contents/Resources/bin/orca")
    }

    /// Select the session's worktree by path; `--json` gives an `ok` flag we can read instead of trusting the exit code.
    public static func arguments(cwd: String) -> [String] {
        ["worktree", "activate", "--worktree", "path:" + cwd, "--json"]
    }

    public enum Select: Equatable {
        /// The CLI exited 0 and answered `ok: true`.
        case selected
        /// Exit 0, but the answer was missing or unreadable: we cannot confirm it.
        case unconfirmed
        /// No CLI, it did not run, timed out, exited non-zero, or answered `ok: false`. The reason is for the log only.
        case failed(String)

        /// The same answer in the shared step vocabulary.
        public var step: JumpPlan.StepResult {
            switch self {
            case .selected: return .done
            case .unconfirmed: return .unconfirmed
            case .failed(let why): return .failed(why)
            }
        }
    }

    public static func interpret(exitStatus: Int32, stdout: Data) -> Select {
        guard exitStatus == 0 else { return .failed("exit \(exitStatus)") }
        guard let obj = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any],
              let ok = obj["ok"] as? Bool else { return .unconfirmed }
        return ok ? .selected : .failed("ok:false")
    }

    /// What the jump reports once the workspace select has been tried: the one shared verdict path.
    public static func finalVerdict(_ app: ActivationOutcome.Verdict, select: Select) -> ActivationOutcome.Verdict {
        JumpPlan.finalVerdict(app, step: select.step)
    }
}
