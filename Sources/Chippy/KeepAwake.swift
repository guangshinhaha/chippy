import AppKit
import ChippyCore
import Combine
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac awake while agents work (#40).
/// Layer 1 (no admin): an IOPMAssertion that blocks idle sleep with the lid open.
/// Layer 2 (opt-in, one-time admin setup): `sudo -n pmset -a disablesleep 1|0` for lid-closed.
/// Policy lives in ChippyCore/AwakePolicy.swift; this file only touches the system.
@MainActor
final class KeepAwake {
    private let model: NotchModel
    private let defaults = UserDefaults.standard
    private var assertion: IOPMAssertionID = 0
    private var lastWorking: Date?
    private var sub: AnyCancellable?
    private var timer: Timer?
    private var lowBattery = false
    private lazy var disabler = SleepDisabler(marker: Self.marker) { on, done in
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.runPmset(on)
            DispatchQueue.main.async { done(ok) }
        }
    }

    private let parentItem = NSMenuItem(), statusItem = NSMenuItem(), awakeForItem = NSMenuItem()
    private let lidSetupItem = NSMenuItem(), lidRemoveItem = NSMenuItem()
    private var modeItems: [AwakeMode: NSMenuItem] = [:]
    private var durationItems: [AwakeDuration: NSMenuItem] = [:]

    private static let marker = ChippyPaths.supportDir.appendingPathComponent("disablesleep-on")
    private static let pmset = "/usr/bin/pmset"
    private static let kMode = "keepAwake.mode", kUntil = "keepAwake.until", kDuration = "keepAwake.duration"
    private static let kOldEnabled = "keepAwake.enabled", kOldLid = "keepAwake.lidClosed"

    /// Chosen mode and absolute deadline (nil = no deadline). Persisted; the effective mode is derived from them.
    private var mode: AwakeMode
    private var until: Date?
    /// The duration the user picked; cleared with the deadline so the radio never drifts with the countdown.
    private var duration: AwakeDuration = .indefinite
    static var setupInstalled: Bool { FileManager.default.fileExists(atPath: SudoersRule.path) }

    init(model: NotchModel) {
        self.model = model
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Self.kMode), let m = AwakeMode(rawValue: raw) {
            mode = m
        } else {
            // One-time migration; the old keys are left alone.
            mode = AwakePolicy.migrate(enabled: d.bool(forKey: Self.kOldEnabled), lidClosed: d.bool(forKey: Self.kOldLid),
                                      setupInstalled: Self.setupInstalled)
            d.set(mode.rawValue, forKey: Self.kMode)
        }
        until = d.object(forKey: Self.kUntil) is Double ? Date(timeIntervalSince1970: d.double(forKey: Self.kUntil)) : nil
        duration = until == nil ? .indefinite : (AwakeDuration(rawValue: d.integer(forKey: Self.kDuration)) ?? .indefinite)
    }

    private func setMode(_ m: AwakeMode, until u: Date?, duration dur: AwakeDuration = .indefinite) {
        mode = m; until = u; duration = u == nil ? .indefinite : dur
        defaults.set(duration.rawValue, forKey: Self.kDuration)
        defaults.set(m.rawValue, forKey: Self.kMode)
        if let u { defaults.set(u.timeIntervalSince1970, forKey: Self.kUntil) } else { defaults.removeObject(forKey: Self.kUntil) }
    }

    /// The deadline and duration still in force: none when off or already past, so a pick is never undone by a stale one.
    private func liveDeadline(_ now: Date) -> (Date, AwakeDuration)? {
        guard mode != .off, let u = until, u > now else { return nil }
        return (u, duration)
    }

    /// Call once at launch. Clears any disablesleep a crashed run left behind, then starts watching.
    func start() {
        disabler.onIdle = { [weak self] in self?.evaluate() }
        if AwakePolicy.shouldClearOnLaunch(markerExists: disabler.markerExists) { disabler.set(false) }
        sub = model.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.evaluate() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.evaluate() }
        }
        evaluate()
    }

    /// Release everything. Called from applicationWillTerminate.
    func stop() {
        timer?.invalidate(); sub = nil
        releaseAssertion()
        disabler.clearBlocking { Self.runPmset($0) }
    }

    // MARK: menu
    /// One parent row with a submenu. Everything keep-awake lives under it so other feature groups can sit beside it.
    func menuItems() -> [NSMenuItem] {
        if parentItem.submenu == nil { buildSubmenu() }
        refreshMenu()
        return [parentItem]
    }

    private func buildSubmenu() {
        parentItem.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Keep Mac awake")
        let menu = NSMenu(); menu.autoenablesItems = false
        for m in AwakeMode.allCases {
            let i = NSMenuItem(title: m.label,
                               action: #selector(modePicked(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = m.rawValue
            modeItems[m] = i; menu.addItem(i)
        }
        menu.addItem(.separator())
        awakeForItem.title = "Awake for"
        let dsub = NSMenu(); dsub.autoenablesItems = false
        for d in AwakeDuration.allCases {
            let i = NSMenuItem(title: d.label, action: #selector(durationPicked(_:)), keyEquivalent: "")
            i.target = self; i.tag = d.rawValue
            durationItems[d] = i; dsub.addItem(i)
        }
        awakeForItem.submenu = dsub
        menu.addItem(awakeForItem)
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())
        lidSetupItem.title = "Set up lid-closed mode…"
        lidSetupItem.action = #selector(setupClicked); lidSetupItem.target = self
        lidRemoveItem.title = "Remove lid-closed setup…"
        lidRemoveItem.action = #selector(removeSetup); lidRemoveItem.target = self
        menu.addItem(lidSetupItem); menu.addItem(lidRemoveItem)
        parentItem.submenu = menu
    }

    private func refreshMenu() {
        let now = Date()
        let eff = AwakePolicy.effectiveMode(mode: mode, until: until, now: now, setupInstalled: Self.setupInstalled)
        parentItem.title = AwakePolicy.parentTitle(mode: eff, until: until, now: now)
        for (m, i) in modeItems { i.state = m == eff ? .on : .off }
        let nameOK = SudoersRule.isValidUser(NSUserName())
        modeItems[.agentsLid]?.isEnabled = Self.setupInstalled || nameOK
        awakeForItem.isEnabled = eff != .off
        let cur = until == nil ? AwakeDuration.indefinite : duration
        for (d, i) in durationItems { i.state = d == cur ? .on : .off }
        let installed = Self.setupInstalled
        lidSetupItem.isHidden = installed
        lidSetupItem.isEnabled = nameOK
        if !nameOK { lidSetupItem.title = "Lid-closed mode unavailable: account name not allowed" }
        lidRemoveItem.isHidden = !installed
        let hold = assertion != 0
        if disabler.isStuck { statusItem.title = "Awake: could not release, run Remove lid-closed setup" }
        else if eff == .off { statusItem.title = "Awake: off" }
        else if lowBattery { statusItem.title = "Lid-closed mode paused: battery under \(AwakePolicy.lowBatteryPercent)%" }
        else if disabler.isOn { statusItem.title = "Awake: agents working (lid closed OK)" }
        else if hold { statusItem.title = "Awake: agents working" }
        else { statusItem.title = "Awake: idle (Mac can sleep)" }
    }

    @objc private func modePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let picked = AwakeMode(rawValue: raw) else { return }
        if picked == .agentsLid, !Self.setupInstalled {
            // Run setup first; if it is cancelled or fails the previous mode stays.
            guard installSetup() else { evaluate(); return }
        }
        let live = picked == .off ? nil : liveDeadline(Date())
        setMode(picked, until: live?.0, duration: live?.1 ?? .indefinite)
        evaluate()
    }

    @objc private func durationPicked(_ sender: NSMenuItem) {
        guard mode != .off, let d = AwakeDuration(rawValue: sender.tag) else { return }
        setMode(mode, until: d.deadline(from: Date()), duration: d)
        evaluate()
    }

    @objc private func setupClicked() {
        if installSetup() {
            let live = liveDeadline(Date())
            setMode(.agentsLid, until: live?.0, duration: live?.1 ?? .indefinite)
        }
        evaluate()
    }

    private func installSetup() -> Bool {
        runAdmin(SudoersRule.installScript(user: NSUserName()))
    }

    @objc private func removeSetup() {
        disabler.clearBlocking { Self.runPmset($0) }
        if runAdmin(SudoersRule.removeScript), mode == .agentsLid {
            setMode(.agents, until: until, duration: duration)
        }
        evaluate()
    }

    /// The only place a password dialog can appear: the user types it into the macOS prompt.
    private func runAdmin(_ shell: String?) -> Bool {
        guard let shell else { return false }
        var err: NSDictionary?
        NSAppleScript(source: SudoersRule.appleScript(forShell: shell))?.executeAndReturnError(&err)
        if let err { NSLog("Chippy: admin step failed: \(err[NSAppleScript.errorNumber] ?? "?")") }
        return err == nil
    }

    // MARK: evaluation
    private func evaluate() {
        let now = Date()
        if model.state == .working || model.state == .needsYou { lastWorking = now }
        // Expiry is a hard stop: flip the stored mode to off first so hold and lid both release below, with no debounce.
        if mode != .off, let u = until, now >= u { setMode(.off, until: nil) }
        let eff = AwakePolicy.effectiveMode(mode: mode, until: until, now: now, setupInstalled: Self.setupInstalled)
        let hold = eff != .off && AwakePolicy.shouldHold(state: model.state, lastWorking: lastWorking, now: now)
        if hold { takeAssertion() } else { releaseAssertion() }

        let (pct, onAC) = Self.battery()
        let want = AwakePolicy.lidDecision(hold: hold, lidModeEnabled: eff == .agentsLid, percent: pct, onAC: onAC)
        lowBattery = want == .lowBattery
        // One pmset call at a time; a request made while one is in flight is dropped and redone from onIdle.
        if want == .on { disabler.set(true) } else { disabler.set(false) }
        refreshMenu()
    }

    private func takeAssertion() {
        guard assertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "Chippy: agents working" as CFString, &id)
        if r == kIOReturnSuccess { assertion = id }
    }

    private func releaseAssertion() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion); assertion = 0
    }

    /// Runs `sudo -n pmset -a disablesleep 1|0`. Blocking: call off the main thread (or at terminate).
    private static func runPmset(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    private static func battery() -> (Int?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, true) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (cur * 100 / max, onAC)
        }
        return (nil, true)
    }
}
