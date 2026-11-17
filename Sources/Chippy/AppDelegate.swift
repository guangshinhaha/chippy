import AppKit
import ChippyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?
    private var server: SocketServer?
    private var sweeper: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NotchPanel(model: model)
        buildMenu()
        startServer()
    }

    private func startServer() {
        let server = SocketServer { [weak self] line, conn in
            guard let payload = HookPayload(json: line) else { conn.respond(nil); return }
            if payload.event == "PermissionRequest" {
                // Connection stays open until the notch answers or the hook gives up.
                DispatchQueue.main.async { self?.model.receiveApproval(payload, conn) }
            } else {
                DispatchQueue.main.async { self?.model.apply(payload) }
                conn.respond(nil)
            }
        }
        sweeper = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.model.sweep() }
        do { try server.start(); self.server = server }
        catch { NSLog("Chippy: socket start failed: \(error)") }
    }

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐿"
        let menu = NSMenu()
        let peek = NSMenuItem(title: "Show sessions", action: #selector(peekSessions), keyEquivalent: "")
        peek.target = self
        menu.addItem(peek)
        menu.addItem(.separator())

        // Everything below is for testing the notch's look, not for real use.
        let dev = NSMenu()
        dev.addItem(header("Testing only: these fake the notch"))
        let live = NSMenuItem(title: "Back to live (follow sessions)", action: #selector(goLive), keyEquivalent: "")
        live.target = self
        dev.addItem(live)
        dev.addItem(.separator())
        dev.addItem(header("Try a demo (fake session)"))
        for (title, kind) in [("Needs your approval", "approval"), ("Two approvals waiting", "queue"), ("Thread finished", "done")] {
            let mi = NSMenuItem(title: title, action: #selector(runDemo(_:)), keyEquivalent: "")
            mi.representedObject = kind; mi.target = self
            dev.addItem(mi)
        }
        dev.addItem(.separator())
        dev.addItem(header("Force state"))
        for s in ChippyState.allCases {
            let mi = NSMenuItem(title: s.title, action: #selector(pickState(_:)), keyEquivalent: "")
            mi.representedObject = s.rawValue; mi.target = self
            dev.addItem(mi)
        }
        dev.addItem(.separator())
        dev.addItem(header("Force size"))
        for d in Density.allCases {
            let mi = NSMenuItem(title: d.title, action: #selector(pickDensity(_:)), keyEquivalent: "")
            mi.representedObject = d.rawValue; mi.target = self
            dev.addItem(mi)
        }
        let devItem = NSMenuItem(title: "Developer (testing only)", action: nil, keyEquivalent: "")
        devItem.submenu = dev
        menu.addItem(devItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Chippy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func header(_ t: String) -> NSMenuItem {
        let mi = NSMenuItem(title: t, action: nil, keyEquivalent: ""); mi.isEnabled = false; return mi
    }

    @objc private func pickState(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let s = ChippyState(rawValue: raw) { model.debugLock = true; model.state = s }
    }

    @objc private func runDemo(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String,
              let exe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("chippy-hook") else { return }
        model.debugLock = false
        let p = Process(); p.executableURL = exe; p.arguments = ["demo", kind]
        try? p.run()
    }

    @objc private func peekSessions() { model.toggleOpen() }

    @objc private func goLive() { model.debugLock = false }

    @objc private func pickDensity(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = Density(rawValue: raw) { model.debugLock = true; model.density = d }
    }
}
