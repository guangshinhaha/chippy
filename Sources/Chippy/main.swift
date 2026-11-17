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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon
    app.run()
}
