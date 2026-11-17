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
    private let kEnabled = "keepAwake.enabled", kLid = "keepAwake.lidClosed"
    private var assertion: IOPMAssertionID = 0
    private var lastWorking: Date?
    private var sub: AnyCancellable?
    private var timer: Timer?
    private var lowBattery = false
    private var lidOn = false

    private let toggleItem = NSMenuItem(), lidItem = NSMenuItem(), removeItem = NSMenuItem(), statusItem = NSMenuItem()

    private static let marker = ChippyPaths.supportDir.appendingPathComponent("disablesleep-on")
    private static let pmset = "/usr/bin/pmset"

    var enabled: Bool { defaults.bool(forKey: kEnabled) }
    var lidMode: Bool { defaults.bool(forKey: kLid) && Self.setupInstalled }
    static var setupInstalled: Bool { FileManager.default.fileExists(atPath: SudoersRule.path) }

    init(model: NotchModel) { self.model = model }

    /// Call once at launch. Clears any disablesleep a crashed run left behind, then starts watching.
    func start() {
        if AwakePolicy.shouldClearOnLaunch(markerExists: FileManager.default.fileExists(atPath: Self.marker.path)) {
            _ = setDisableSleep(false)
        }
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
        if lidOn || FileManager.default.fileExists(atPath: Self.marker.path) { _ = setDisableSleep(false) }
    }

    // MARK: menu
    func menuItems() -> [NSMenuItem] {
        toggleItem.title = "Keep Mac awake while agents work"
        toggleItem.action = #selector(toggleEnabled); toggleItem.target = self
        lidItem.action = #selector(lidClicked); lidItem.target = self
        removeItem.title = "Remove lid-closed setup"
        removeItem.action = #selector(removeSetup); removeItem.target = self
        statusItem.isEnabled = false
        refreshMenu()
        return [toggleItem, lidItem, removeItem, statusItem]
    }

    private func refreshMenu() {
        toggleItem.state = enabled ? .on : .off
        lidItem.title = Self.setupInstalled ? "Also when the lid is closed" : "Also when the lid is closed…"
        lidItem.state = lidMode ? .on : .off
        removeItem.isHidden = !Self.setupInstalled
        let hold = assertion != 0
        if !enabled { statusItem.title = "Awake: off" }
        else if lowBattery { statusItem.title = "Lid-closed mode paused: battery under \(AwakePolicy.lowBatteryPercent)%" }
        else if lidOn { statusItem.title = "Awake: agents working (lid closed OK)" }
        else if hold { statusItem.title = "Awake: agents working" }
        else { statusItem.title = "Awake: idle (Mac can sleep)" }
    }

    @objc private func toggleEnabled() {
        defaults.set(!enabled, forKey: kEnabled)
        evaluate()
    }

    @objc private func lidClicked() {
        if Self.setupInstalled {
            defaults.set(!defaults.bool(forKey: kLid), forKey: kLid)
        } else if runAdmin(SudoersRule.installScript(user: NSUserName())) {
            defaults.set(true, forKey: kLid)
            defaults.set(true, forKey: kEnabled)
        }
        evaluate()
    }

    @objc private func removeSetup() {
        _ = setDisableSleep(false)
        if runAdmin(SudoersRule.removeScript) { defaults.set(false, forKey: kLid) }
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
        let hold = enabled && AwakePolicy.shouldHold(state: model.state, lastWorking: lastWorking, now: now)
        if hold { takeAssertion() } else { releaseAssertion() }

        let (pct, onAC) = Self.battery()
        let want = AwakePolicy.lidDecision(hold: hold, lidModeEnabled: lidMode, percent: pct, onAC: onAC)
        lowBattery = want == .lowBattery
        if want == .on, !lidOn { lidOn = setDisableSleep(true) }
        else if want != .on, lidOn || FileManager.default.fileExists(atPath: Self.marker.path) {
            if setDisableSleep(false) { lidOn = false }
        }
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

    /// Marker first when turning ON (so a crash mid-way is still recovered); removed only after a confirmed OFF.
    private func setDisableSleep(_ on: Bool) -> Bool {
        let fm = FileManager.default
        if on {
            try? fm.createDirectory(at: Self.marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: Self.marker.path, contents: Data())
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", Self.pmset, "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        var ok = false
        do { try p.run(); p.waitUntilExit(); ok = p.terminationStatus == 0 } catch {}
        if !on, ok { try? fm.removeItem(at: Self.marker) }
        if on, !ok { try? fm.removeItem(at: Self.marker) }
        return ok
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
