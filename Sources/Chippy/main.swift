import AppKit
import ChippyCore

// Render flags are decided before any app setup (#223): a mistyped `--render-*` exits here, so it never creates the
// socket, support files or preferences.
let renderFlag = RenderFlag.parse(CommandLine.arguments)
switch renderFlag {
case .none:
    break
case .unknown, .missingOutput:
    FileHandle.standardError.write(Data(RenderFlag.usage(renderFlag).utf8))
    exit(2)
case .render(let flag, let out):
    MainActor.assumeIsolated {
        switch flag {
        case "--render-gallery": Gallery.render(to: out)
        case "--render-done-detail": Gallery.renderDoneDetail(to: out)
        case "--render-question": Gallery.renderQuestion(to: out)
        case "--render-terminal-chip": Gallery.renderTerminalChip(to: out)
        case "--render-approval": Gallery.renderApproval(to: out)
        case "--render-plan": Gallery.renderPlan(to: out)
        case "--render-tab": Gallery.renderTab(to: out)
        case "--render-away": Gallery.renderAway(to: out)
        case "--render-resting": Gallery.renderResting(to: out)
        case "--render-waiting": Gallery.renderWaiting(to: out)
        case "--render-needs-finished": Gallery.renderNeedsFinished(to: out)
        case "--render-finished-overflow": Gallery.renderFinishedOverflow(to: out)
        case "--render-badge-dot": Gallery.renderBadgeDot(to: out)
        case "--render-identity": Gallery.renderIdentity(to: out)
        case "--render-glance": Gallery.renderGlance(to: out)
        case "--render-panel": Gallery.renderPanel(to: out)
        case "--render-mixed-header": Gallery.renderMixedHeader(to: out)
        default:
            FileHandle.standardError.write(Data(RenderFlag.usage(.unknown(flag)).utf8))
            exit(2)
        }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon
    app.run()
}
