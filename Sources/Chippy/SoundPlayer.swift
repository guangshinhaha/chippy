import AppKit
import ChippyCore

/// Plays subtle built-in sounds (#67). Decisions live in ChippyCore/SoundPolicy.swift; this only reads
/// frontmost/lock state and plays. Focus modes and screen recording have no reliable public API, so they are not handled.
@MainActor
final class SoundPlayer {
    static let key = "sounds.enabled"
    private let defaults = UserDefaults.standard
    private var cooldowns = SoundCooldowns()
    private var playing: [NSSound] = []
    private var locked = SoundPlayer.screenIsLocked()
    private var warnedMissing = false
    private var observers: [NSObjectProtocol] = []

    private static func screenIsLocked() -> Bool {
        let d = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (d?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    init() {
        defaults.register(defaults: [Self.key: true])
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = true }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked = false }
        })
    }

    func sessionEnded(_ id: String) { cooldowns.prune(session: id) }

    var enabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    func handle(_ kind: SoundKind, sessionId: String, host: HostInfo?, now: Date = Date()) {
        let front = NSWorkspace.shared.frontmostApplication
        let pidIsApp = host?.pid.map { NSRunningApplication(processIdentifier: $0) != nil } ?? false
        let frontmost = SoundPolicy.isHostFrontmost(host: host, frontmostPid: front?.processIdentifier,
                                                    frontmostBundle: front?.bundleIdentifier, pidIsRunningApp: pidIsApp)
        guard SoundPolicy.shouldPlay(kind: kind, enabled: enabled, hostFrontmost: frontmost, locked: locked,
                                     lastPlayed: cooldowns.lastPlayed(kind, session: sessionId), now: now) else { return }
        // The named sound is a shared instance and play() on a playing one is a no-op: play a copy.
        guard let s = (NSSound(named: kind == .needsYou ? "Pop" : "Tink")?.copy() as? NSSound) else {
            if !warnedMissing { warnedMissing = true; NSLog("Chippy: built-in sound missing") }
            return
        }
        playing.removeAll { !$0.isPlaying }
        playing.append(s)
        _ = s.play()
        cooldowns.record(kind, session: sessionId, at: now)
    }
}
