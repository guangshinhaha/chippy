import AppKit
import ChippyCore
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?
    private var server: SocketServer?
    private var sweeper: Timer?
    private var outsideClick: Any?
    private var escKey: Any?
    private let hotKeys = HotKeys()
    private var shortcutCard: (id: String, shownAt: Date)?
    private var pendingWatch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NotchPanel(model: model)
        buildMenu()
        startServer()
        startShortcuts()
        // Clicks in any other app are "outside the notch": fold the detail back to its glance.
        // Esc in any app folds the detail. Global key events need Accessibility permission; without it only clicks work.
        escKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { DispatchQueue.main.async { self?.model.closeDetail() } }
        }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.model.closeDetail() }
        }
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

    // MARK: keyboard shortcuts (#36). Keys exist only while a card is on screen.
    private func startShortcuts() {
        hotKeys.onAction = { [weak self] in self?.handleShortcut($0) }
        pendingWatch = model.$pending.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncShortcuts() }
    }

    private func syncShortcuts() {
        guard let req = model.pending.first else { shortcutCard = nil; hotKeys.unregister(); return }
        if shortcutCard?.id == req.id { return } // same card: keep keys and its shownAt
        shortcutCard = (req.id, Date())
        if let qs = req.questions {
            hotKeys.register(ShortcutKeys.question(optionCount: qs.map { $0.options.count }.max() ?? 0))
        } else {
            hotKeys.register(ShortcutKeys.approval)
        }
    }

    private func handleShortcut(_ action: ShortcutAction) {
        // Only the card on screen, only once it has been visible long enough.
        guard let req = model.pending.first, let card = shortcutCard, card.id == req.id,
              ShortcutGate.allows(shownAt: card.shownAt) else { return }
        switch action {
        case .allow where req.questions == nil: model.resolve(req.id, .allow)
        case .deny where req.questions == nil: model.resolve(req.id, .deny)
        case .always where req.questions == nil: model.resolve(req.id, .always)
        case .option where req.questions != nil: ShortcutBus.events.send(ShortcutEvent(requestId: req.id, action: action))
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐿"
        let menu = NSMenu()
        let peek = NSMenuItem(title: "Show sessions", action: #selector(peekSessions), keyEquivalent: "")
        peek.target = self
        menu.addItem(peek)
        let glance = NSMenuItem(title: "Show reply text beside the camera", action: #selector(toggleGlance(_:)), keyEquivalent: "")
        glance.target = self; glance.state = model.showReplyInGlance ? .on : .off
        menu.addItem(glance)
        menu.addItem(.separator())

        // Everything below is for testing the notch's look, not for real use.
        let dev = NSMenu()
        dev.addItem(header("Testing only: these fake the notch"))
        let live = NSMenuItem(title: "Back to live (follow sessions)", action: #selector(goLive), keyEquivalent: "")
        live.target = self
        dev.addItem(live)
        dev.addItem(.separator())
        dev.addItem(header("Try a demo (fake session)"))
        for (title, kind) in [("Needs your approval", "approval"), ("Two approvals waiting", "queue"), ("A question from Claude", "question"), ("Thread finished", "done")] {
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

    @objc private func toggleGlance(_ sender: NSMenuItem) {
        model.showReplyInGlance.toggle()
        sender.state = model.showReplyInGlance ? .on : .off
    }

    @objc private func peekSessions() { model.toggleOpen() }

    @objc private func goLive() { model.debugLock = false }

    @objc private func pickDensity(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = Density(rawValue: raw) { model.debugLock = true; model.density = d }
    }
}
