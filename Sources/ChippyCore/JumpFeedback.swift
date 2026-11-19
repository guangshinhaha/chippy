import Foundation

/// What the Open button says after a jump (#136). Pure, so each verdict's wording is tested and none shares another's.
public enum JumpFeedback {
    public struct Text: Equatable {
        public let title: String
        public let hint: String
        public let help: String
    }

    /// nil when the jump needs no message. `.landed` and `.landedUnverified` are both treated as success: the app is in front,
    /// the button closes the chip and shows nothing. `.landedUnverified` only means the window check could not confirm which
    /// window, and a warning for a jump that most likely worked would teach people to ignore the button.
    public static func text(for verdict: ActivationOutcome.Verdict, appName: String) -> Text? {
        switch verdict {
        case .landed, .landedUnverified:
            return nil
        case .offSpace:
            return Text(title: "On another Space", hint: "\(appName) is frontmost; switch Space",
                        help: "\(appName) is frontmost but its window is on another Space. Switch Space (Ctrl-arrow) or enable System Settings > Desktop & Dock > switch to a Space with open windows.")
        case .workspaceNotSelected:
            return Text(title: "Not selected", hint: "pick the workspace yourself",
                        help: "\(appName) came forward, but Chippy couldn't select this session's workspace in it. Pick it from the sidebar.")
        case .notFrontmost:
            return Text(title: "Couldn't open", hint: "switch to it yourself",
                        help: "Chippy couldn't bring the app forward. Switch to it from the Dock or Cmd-Tab.")
        }
    }
}
