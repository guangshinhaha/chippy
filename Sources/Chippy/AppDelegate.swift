import AppKit
import ChippyCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?
    private var server: SocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NotchPanel(model: model)
        panel?.orderFrontRegardless()
        buildMenu()
        startServer()
    }

    private func startServer() {
        let server = SocketServer { [weak self] line, conn in
            // Fire-and-forget events: parse, update the UI, close. (Approvals reply later, see #5.)
            if let payload = HookPayload(json: line) {
                DispatchQueue.main.async { self?.model.apply(payload) }
            }
            conn.respond(nil)
        }
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

    @objc private func goLive() { model.debugLock = false; model.state = .idle; model.density = .collapsed }

    @objc private func pickDensity(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = Density(rawValue: raw) { model.debugLock = true; model.density = d }
    }
}
