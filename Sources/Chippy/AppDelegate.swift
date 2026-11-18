import AppKit
import ChippyCore
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = NotchModel()
    private var panel: NotchPanel?
    private var statusItem: NSStatusItem?
    /// The one menu: the status item shows it, and so do the notch's right-click and gear (never rebuilt).
    private var mainMenu: NSMenu?
    private let todayItem = NSMenuItem(), weekItem = NSMenuItem()
    private let focusHintItem = NSMenuItem(title: "Focus detection needs Full Disk Access (open Settings)", action: #selector(openFullDiskAccess), keyEquivalent: "")
    private var server: SocketServer?
    private var sweeper: Timer?
    private var outsideClick: Any?
    private var escKey: Any?
    private let hotKeys = HotKeys()
    private var shortcutCard: (id: String, shownAt: Date)?
    private var pendingWatch: AnyCancellable?
    private var stepWatch: AnyCancellable?
    private var questionStep = 0
    private var menuKey: (Date?, Int, Date, Int)?
    private var menuGen = 0
    private lazy var tour = TourRunner(model: model)
    private lazy var keepAwake = KeepAwake(model: model)
    private let sounds = SoundPlayer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NotchPanel(model: model)
        panel?.onMenu = { [weak self] at, centered in self?.popMenu(at: at, centered: centered) }
        model.onSound = { [weak self] kind, id, host, quiet in self?.sounds.handle(kind, sessionId: id, host: host, quiet: quiet) }
        model.awaySignal = { // #92: lock and idle read live; nothing is stored beyond the away start time
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            return (SoundPlayer.screenIsLocked(), idle)
        }
        model.silence = { [weak self] in self?.sounds.silenceState() ?? SilenceState() }
        model.onSessionEnd = { [weak self] id in self?.sounds.sessionEnded(id) }
        model.planCardEnabled = UserDefaults.standard.bool(forKey: Self.planCardKey) // experimental (#91), default off
        model.freeTextReplyEnabled = UserDefaults.standard.bool(forKey: Self.freeTextKey) // experimental (#94), default off
        buildMenu()
        startServer()
        startShortcuts()
        // The repair alert is modal: on first launch it waits until the tour is over.
        if tour.willRunOnFirstLaunch {
            tour.onFinish = { [weak self] in self?.offerHookRepair() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.offerHookRepair() }
        }
        tour.runOnFirstLaunch()
        keepAwake.start()
        // Clicks in any other app are "outside the notch": fold the detail back to its glance.
        // Esc in any app folds the detail. Global key events need Accessibility permission; without it only clicks work.
        escKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, self?.model.replyFieldFocused != true { DispatchQueue.main.async { self?.model.closeDetail() } }
        }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.panel?.inMenuTracking == true { return } // dismissing our own menu is not an outside click
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
        stepWatch = ShortcutBus.steps.receive(on: DispatchQueue.main).sink { [weak self] s in
            guard let self, let req = self.model.shownPending, req.id == s.requestId, req.questions != nil else { return }
            self.questionStep = s.step
            self.registerQuestionKeys(req) // the next question may have fewer options
        }
        pendingWatch = Publishers.MergeMany([model.$pending.map { _ in () }.eraseToAnyPublisher(), model.$listOpen.map { _ in () }.eraseToAnyPublisher(),
                                      model.$focus.map { _ in () }.eraseToAnyPublisher(), model.$folded.map { _ in () }.eraseToAnyPublisher(), model.$partials.map { _ in () }.eraseToAnyPublisher(),
                                      model.$expandedPlans.map { _ in () }.eraseToAnyPublisher(),
                                      model.$replyFocusOwner.map { _ in () }.eraseToAnyPublisher(), model.$freeTextReplyEnabled.map { _ in () }.eraseToAnyPublisher()])
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.syncShortcuts() }
    }

    /// The key set last asked of HotKeys, kept only while it registered in full; a failed registration is retried on the next sync.
    private var lastDesiredKeys: [ShortcutAction]?

    private func syncShortcuts() {
        guard let req = model.shownPending else { shortcutCard = nil; lastDesiredKeys = nil; hotKeys.unregister(); return }
        // Typing in the reply field (#94): no card hotkey may act or swallow a key until focus leaves it.
        if model.replyFieldFocused { shortcutCard = nil; lastDesiredKeys = nil; hotKeys.unregister(); return }
        let seed = min(model.partials[req.id]?.step ?? 0, max((req.questions?.count ?? 1) - 1, 0)) // re-seeded on every sync, step 0 included; never past the last question
        if shortcutCard?.id == req.id { // same card: keep keys and its shownAt
            if req.questions != nil, questionStep != seed { questionStep = seed; registerQuestionKeys(req) }
            if req.isPlanApproval { registerPlanKeys(req) } // expanding or folding the plan changes whether Y may approve
            return
        }
        shortcutCard = (req.id, Date())
        lastDesiredKeys = nil
        questionStep = seed
        if req.questions != nil {
            registerQuestionKeys(req)
        } else if req.isPlanApproval {
            registerPlanKeys(req)
        } else {
            registerKeys(ShortcutKeys.approval)
        }
    }

    /// A plan has no "always" key, and approves by key only once the reader has the whole card open.
    private func registerPlanKeys(_ req: PendingRequest) {
        let mayApprove = model.hotkeyMayApprove(req)
        let keys = ShortcutKeys.approval.filter { k in
            switch k.action {
            case .allow: return mayApprove
            case .always: return false
            default: return true
            }
        }
        let desired = keys.map { $0.action }
        if lastDesiredKeys == desired { return } // same desired set and it registered in full: no churn
        lastDesiredKeys = registerKeys(keys) ? desired : nil
    }

    /// Digits for the question on screen only, so an unused digit isn't swallowed.
    private func registerQuestionKeys(_ req: PendingRequest) {
        let counts = (req.questions ?? []).map { $0.options.count }
        registerKeys(ShortcutKeys.question(optionCount: ShortcutGate.optionCount(step: questionStep, counts: counts)))
    }

    /// The one door to HotKeys.register: while the reply field has focus (#94) no card key may be registered, whoever asks
    /// (sync, the step sink, a plan toggle), so a typed digit or Y/N can never be swallowed.
    @discardableResult
    private func registerKeys(_ keys: [(keyCode: Int, action: ShortcutAction)]) -> Bool {
        if model.replyFieldFocused { hotKeys.unregister(); lastDesiredKeys = nil; return false }
        return hotKeys.register(keys)
    }

    private func handleShortcut(_ action: ShortcutAction) {
        // Only the card on screen, only once it has been visible long enough.
        guard !model.replyFieldFocused, let req = model.shownPending, let card = shortcutCard, card.id == req.id,
              ShortcutGate.allows(shownAt: card.shownAt) else { return }
        switch action {
        case .allow where req.questions == nil && model.hotkeyMayApprove(req): model.resolve(req.id, .allow)
        case .deny where req.questions == nil: model.resolve(req.id, .deny)
        case .always where req.questions == nil: model.resolve(req.id, .always) // plans have no always key, and resolve refuses it anyway
        case .option where req.questions != nil: ShortcutBus.events.send(ShortcutEvent(requestId: req.id, action: action))
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) { server?.stop(); keepAwake.stop() }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐿"
        let menu = NSMenu()
        menu.delegate = self
        for i in [todayItem, weekItem] { i.isEnabled = false; menu.addItem(i) }
        focusHintItem.target = self; focusHintItem.isHidden = true; menu.addItem(focusHintItem)
        menu.addItem(.separator())
        let peek = NSMenuItem(title: "Show sessions", action: #selector(peekSessions), keyEquivalent: "")
        peek.target = self
        menu.addItem(peek)
        let glance = NSMenuItem(title: "Show reply text beside the camera", action: #selector(toggleGlance(_:)), keyEquivalent: "")
        glance.target = self; glance.state = model.showReplyInGlance ? .on : .off
        menu.addItem(glance)
        let soundItem = NSMenuItem(title: "Play sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundItem.target = self; soundItem.state = sounds.enabled ? .on : .off
        menu.addItem(soundItem)
        let focusItem = NSMenuItem(title: "Quiet during Focus (best effort, needs Full Disk Access)", action: #selector(toggleFocusQuiet(_:)), keyEquivalent: "")
        focusItem.target = self; focusItem.state = sounds.focusQuietEnabled ? .on : .off
        menu.addItem(focusItem)
        let planItem = NSMenuItem(title: "Plan approval card (experimental)", action: #selector(togglePlanCard(_:)), keyEquivalent: "")
        planItem.target = self; planItem.state = model.planCardEnabled ? .on : .off
        menu.addItem(planItem)
        let freeItem = NSMenuItem(title: "Free-text reply (experimental)", action: #selector(toggleFreeText(_:)), keyEquivalent: "")
        freeItem.target = self; freeItem.state = model.freeTextReplyEnabled ? .on : .off
        menu.addItem(freeItem)
        let tourItem = NSMenuItem(title: "Show me how it works", action: #selector(runTour), keyEquivalent: "")
        tourItem.target = self
        menu.addItem(tourItem)
        repairItem.target = self; repairItem.isHidden = true
        menu.addItem(repairItem)
        for i in keepAwake.menuItems() { menu.addItem(i) }
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
        mainMenu = menu
        statusItem = item
    }

    /// Show the shared menu at a screen point: under the notch (centred) for right-click, at the pointer for the gear.
    /// It is the status item's own menu (same items and delegate), so both entry points always agree.
    private func popMenu(at p: NSPoint, centered: Bool) {
        guard let menu = mainMenu else { return }
        panel?.inMenuTracking = true // popUp blocks until the menu closes; clicks that dismiss it must not fold the panel
        defer { panel?.inMenuTracking = false }
        menu.popUp(positioning: nil, at: NSPoint(x: centered ? p.x - menu.size.width / 2 : p.x, y: p.y), in: nil)
    }

    // MARK: stale hook repair (#99)

    private let repairItem = NSMenuItem(title: "Repair Claude hook…", action: #selector(repairHook), keyEquivalent: "")
    private var offeredRepair = false
    private let repairDismissedKey = "hookRepairDismissedReason"

    private var claudeSettingsPath: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path }

    private func hookStaleness() -> [SettingsInstaller.Staleness] {
        guard let d = FileManager.default.contents(atPath: claudeSettingsPath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return SettingsInstaller.staleness(o)
    }

    private func repairReason(_ s: [SettingsInstaller.Staleness]) -> String {
        if s.contains(.missingPermissionRequest) { return "Claude's hook for Chippy has no approval relay, so approvals and questions will not reach the notch." }
        if s.contains(.legacyApprovalTimeout) { return "Claude's hook for Chippy still uses the old 20 second approval wait. A timeout of 20 will become 60; a custom value other than 20 is kept." }
        if s.contains(.missingQuestionFlag) { return "Claude's hook for Chippy predates the longer question wait, so questions can be cut off early." }
        return "Claude's hook timeout for Chippy is shorter than its wait, so Claude can cut off a question or approval early."
    }

    private func repairMenuTitle(_ s: [SettingsInstaller.Staleness]) -> String {
        if s.contains(.missingPermissionRequest) { return "Repair Claude hook (approvals missing)…" }
        if s.contains(.legacyApprovalTimeout) { return "Repair Claude hook (old 20s wait)…" }
        if s.contains(.missingQuestionFlag) { return "Repair Claude hook (no question flag)…" }
        return "Repair Claude hook (timeout too short)…"
    }

    private func offerHookRepair() {
        let s = hookStaleness()
        guard !s.isEmpty else { return }
        // "Later" holds for this session and, keyed to the reason, across launches until the reason changes.
        let key = s.map { "\($0)" }.joined(separator: ",")
        guard !offeredRepair, UserDefaults.standard.string(forKey: repairDismissedKey) != key else { return }
        offeredRepair = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Claude's hook for Chippy is out of date"
        a.informativeText = repairReason(s) + " Repair opens Terminal, shows the change, and asks before writing. A backup is kept."
        a.addButton(withTitle: "Repair…"); a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { repairHook() } else { UserDefaults.standard.set(key, forKey: repairDismissedKey) }
    }

    private func repairFailed(_ why: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Couldn't start the repair"
        a.informativeText = why
        a.runModal()
    }

    /// Runs the same `chippy-hook install` as the CLI (backup + diff + confirm) in Terminal.
    @objc private func repairHook() {
        guard let exe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("chippy-hook") else {
            return repairFailed("Chippy can't find its own chippy-hook tool.")
        }
        // A hook that points into a disk image, a translocated copy or a temp dir breaks once that goes away.
        if SettingsInstaller.isTransientPath(exe.path) {
            return repairFailed("Chippy is running from a temporary location. Move it to Applications, reopen it, then repair.")
        }
        let q = "'" + exe.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("chippy-repair-hook-\(UUID().uuidString).command")
        do {
            // trap removes the script however Terminal ends it: normal exit, Ctrl-C, or closing the window.
            let qs = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            try "#!/bin/zsh\ntrap \"rm -f -- \(qs)\" EXIT HUP INT TERM\n\(q) install\necho\nread -k 1 '?Press any key to close.'\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return repairFailed("Couldn't write the repair script: \(error.localizedDescription)")
        }
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            return repairFailed("The repair script isn't runnable.")
        }
        NSWorkspace.shared.open(script, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, err in
            guard let err else { return }
            DispatchQueue.main.async { self?.repairFailed("Couldn't open Terminal: \(err.localizedDescription)") }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        focusHintItem.isHidden = !sounds.focusUnreadable // a hint in the menu only, never a nag
        let stale = hookStaleness()
        repairItem.isHidden = stale.isEmpty
        if !stale.isEmpty { repairItem.title = repairMenuTitle(stale) }
        // The log can be large: read it off the main thread, and only when the file changed.
        // Keyed on mtime, size and today's date, so a new day recomputes.
        let url = EventLog().url
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (mtime: attrs?[.modificationDate] as? Date, size: (attrs?[.size] as? Int) ?? 0)
        let midnight = Calendar.current.startOfDay(for: Date())
        let key = (stamp.mtime, stamp.size, midnight, Int(Date().timeIntervalSince1970 / 300)) // 5-min bucket: the week window slides
        menuGen += 1; let gen = menuGen
        if let last = menuKey, last == key { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dated = WaitSummary.dated(EventLog.read(url))
            let today = WaitSummary(dated: dated, since: midnight).menuLine(label: "Waited on you today")
            let week = WaitSummary(dated: dated, since: Date().addingTimeInterval(-7 * 86_400)).menuLine(label: "This week", showAsks: true)
            DispatchQueue.main.async {
                guard let self, gen == self.menuGen else { return } // a newer open superseded this read
                self.todayItem.title = today; self.weekItem.title = week
                self.menuKey = key
            }
        }
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

    @objc private func runTour() { tour.start() }

    @objc private func toggleGlance(_ sender: NSMenuItem) {
        model.showReplyInGlance.toggle()
        sender.state = model.showReplyInGlance ? .on : .off
    }

    @objc private func toggleSounds(_ sender: NSMenuItem) {
        sounds.enabled.toggle()
        sender.state = sounds.enabled ? .on : .off
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    private static let planCardKey = "planCard"
    @objc private func togglePlanCard(_ sender: NSMenuItem) {
        model.planCardEnabled.toggle()
        UserDefaults.standard.set(model.planCardEnabled, forKey: Self.planCardKey)
        sender.state = model.planCardEnabled ? .on : .off
    }

    private static let freeTextKey = "freeTextReply"
    @objc private func toggleFreeText(_ sender: NSMenuItem) {
        model.freeTextReplyEnabled.toggle()
        UserDefaults.standard.set(model.freeTextReplyEnabled, forKey: Self.freeTextKey)
        sender.state = model.freeTextReplyEnabled ? .on : .off
    }

    @objc private func toggleFocusQuiet(_ sender: NSMenuItem) {
        sounds.focusQuietEnabled.toggle()
        sender.state = sounds.focusQuietEnabled ? .on : .off
    }

    @objc private func peekSessions() { model.toggleOpen() }

    @objc private func goLive() { model.debugLock = false }

    @objc private func pickDensity(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = Density(rawValue: raw) { model.debugLock = true; model.density = d }
    }
}
