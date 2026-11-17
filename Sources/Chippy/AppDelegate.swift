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
        let live = NSMenuItem(title: "Live (follow sessions)", action: #selector(goLive), keyEquivalent: "")
        live.target = self
        menu.addItem(live)
        let peek = NSMenuItem(title: "Show / hide sessions", action: #selector(peekSessions), keyEquivalent: "")
        peek.target = self
        menu.addItem(peek)
        menu.addItem(header("State (debug)"))
        for s in ChippyState.allCases {
            let mi = NSMenuItem(title: s.title, action: #selector(pickState(_:)), keyEquivalent: "")
            mi.representedObject = s.rawValue; mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(header("Density (debug)"))
        for d in Density.allCases {
            let mi = NSMenuItem(title: d.title, action: #selector(pickDensity(_:)), keyEquivalent: "")
            mi.representedObject = d.rawValue; mi.target = self
            menu.addItem(mi)
        }
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

    @objc private func peekSessions() { model.toggleOpen() }

    @objc private func goLive() { model.debugLock = false }

    @objc private func pickDensity(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = Density(rawValue: raw) { model.debugLock = true; model.density = d }
    }
}
