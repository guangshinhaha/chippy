import AppKit
import ChippyCore

/// Plays subtle built-in sounds (#67). Decisions live in ChippyCore/SoundPolicy.swift; this only reads
/// frontmost/lock state and plays. Focus modes and screen recording have no reliable public API, so they are not handled.
@MainActor
final class SoundPlayer {
    static let key = "sounds.enabled"
    private let defaults = UserDefaults.standard
    private var lastPlayed: [String: Date] = [:]
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

    var enabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    func handle(_ kind: SoundKind, sessionId: String, host: HostInfo?, now: Date = Date()) {
        let front = NSWorkspace.shared.frontmostApplication
        let frontmost = SoundPolicy.isHostFrontmost(host: host, frontmostPid: front?.processIdentifier,
                                                    frontmostBundle: front?.bundleIdentifier)
        guard SoundPolicy.shouldPlay(kind: kind, enabled: enabled, hostFrontmost: frontmost, locked: locked,
                                     lastPlayed: lastPlayed[sessionId], now: now) else { return }
        lastPlayed[sessionId] = now
        NSSound(named: kind == .needsYou ? "Pop" : "Tink")?.play()
    }
}
