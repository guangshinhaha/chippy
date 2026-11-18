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
    private var locked = false
    private var observers: [NSObjectProtocol] = []

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
        let frontmost = SoundPolicy.isHostFrontmost(host: host, frontmostPid: front?.processIdentifier,
                                                    frontmostBundle: front?.bundleIdentifier)
        guard SoundPolicy.shouldPlay(kind: kind, enabled: enabled, hostFrontmost: frontmost, locked: locked,
                                     lastPlayed: cooldowns.lastPlayed(kind, session: sessionId), now: now) else { return }
        cooldowns.record(kind, session: sessionId, at: now)
        // The named sound is a shared instance and play() on a playing one is a no-op: play a copy.
        guard let s = (NSSound(named: kind == .needsYou ? "Pop" : "Tink")?.copy() as? NSSound) else { return }
        playing.removeAll { !$0.isPlaying }
        playing.append(s)
        s.play()
    }
}
