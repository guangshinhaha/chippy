import AppKit
import os
import ChippyCore

/// Plays subtle built-in sounds (#67). Decisions live in ChippyCore/SoundPolicy.swift; this only reads
/// frontmost/lock state and plays. Quiet state (#95) is lock (live read) plus an opt-in, best-effort Focus read; screen recording has no public API and is not handled.
@MainActor
final class SoundPlayer {
    static let key = "sounds.enabled"
    static let focusQuietKey = "quiet.focus.enabled"
    private let defaults = UserDefaults.standard
    private var cooldowns = SoundCooldowns()
    private var playing: [NSSound] = []
    private let focusCache = FocusCache(read: {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        let reading = SilencePolicy.readFocus(assertionsJSON: try? Data(contentsOf: url))
        if reading == .unknown { SoundPlayer.logFocusUnreadable() }
        return reading
    })
    /// True when Focus state cannot be read (no Full Disk Access), so the menu can say so.
    /// Only meaningful (and only read) when the Focus-quiet toggle is on.
    var focusUnreadable: Bool { focusQuietEnabled && focusCache.unreadable }
    /// Opt-in, off by default: Focus has no public API and needs Full Disk Access. Lock-quiet is always on.
    var focusQuietEnabled: Bool {
        get { defaults.bool(forKey: Self.focusQuietKey) }
        set { defaults.set(newValue, forKey: Self.focusQuietKey); focusCache.invalidate() }
    }
    private static let focusLog = OSAllocatedUnfairLock(initialState: false)
    /// One line, once per launch, no content: Focus could not be read (needs Full Disk Access) so Chippy behaves as if off.
    static func logFocusUnreadable() {
        let first = focusLog.withLock { logged -> Bool in defer { logged = true }; return !logged }
        if first { os_log("Chippy: Focus state unreadable, treating as off", log: .default, type: .info) }
    }
    /// Current quiet state (#95): read once per event by the model, which passes it to both its own decisions and `handle`.
    /// Focus comes from a 2s cache refreshed off the calling thread (fail open until the first read lands).
    /// Lock is re-read from the session dictionary every time (cheap), never latched from notifications, so a missed
    /// unlock can never leave Chippy quiet.
    func silenceState() -> SilenceState {
        SilenceState(focus: focusQuietEnabled && focusCache.current, locked: Self.screenIsLocked())
    }
    private var warnedMissing = false
    private var observers: [NSObjectProtocol] = []

    static func screenIsLocked() -> Bool {
        SilencePolicy.sessionIsLocked(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    init() {
        defaults.register(defaults: [Self.key: true])
        // Lock is read live in silenceState(); these only drop the cached Focus reading so wake / session-active start fresh.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusCache.invalidate() }
            })
        }
    }

    func sessionEnded(_ id: String) { cooldowns.prune(session: id) }

    var enabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    func handle(_ kind: SoundKind, sessionId: String, host: HostInfo?, quiet: SilenceState, now: Date = Date()) {
        let front = NSWorkspace.shared.frontmostApplication
        let pidIsApp = host?.pid.map { NSRunningApplication(processIdentifier: $0) != nil } ?? false
        let frontmost = SoundPolicy.isHostFrontmost(host: host, frontmostPid: front?.processIdentifier,
                                                    frontmostBundle: front?.bundleIdentifier, pidIsRunningApp: pidIsApp)
        guard SoundPolicy.shouldPlay(kind: kind, enabled: enabled, hostFrontmost: frontmost, quiet: quiet.isQuiet,
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
