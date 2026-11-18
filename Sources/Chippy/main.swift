import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-gallery"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.render(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-done-detail"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.renderDoneDetail(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-question"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.renderQuestion(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-terminal-chip"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.renderTerminalChip(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-approval"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.renderApproval(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-plan"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.renderPlan(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-tab"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.renderTab(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-resting"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.renderResting(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-waiting"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.renderWaiting(to: args[i + 1]) }
    exit(0)
}

if let i = args.firstIndex(of: "--render-mixed-header"), i + 1 < args.count {
    MainActor.assumeIsolated { Gallery.renderMixedHeader(to: args[i + 1]) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon
    app.run()
}
