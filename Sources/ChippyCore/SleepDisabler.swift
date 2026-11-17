import Foundation

/// Sequences `pmset -a disablesleep 1|0` calls and the crash-recovery marker (#40).
/// Main-thread only. The runner does the slow work off-thread and calls back on the main thread.
/// Invariants: the marker exists before a `1` is issued; it is removed only after a `0` succeeds;
/// at most one call is in flight, and requests made meanwhile are dropped (owners re-evaluate in `onIdle`).
public final class SleepDisabler {
    public typealias Runner = (_ on: Bool, _ done: @escaping (Bool) -> Void) -> Void

    private let run: Runner
    private let marker: URL
    public private(set) var inFlight = false
    public private(set) var isOn = false
    public private(set) var clearFailed = false
    /// Called on the main thread after each call finishes, so the owner can re-evaluate.
    public var onIdle: (() -> Void)?

    public init(marker: URL, run: @escaping Runner) { self.marker = marker; self.run = run }

    public var markerExists: Bool { FileManager.default.fileExists(atPath: marker.path) }
    /// Something may still be holding SleepDisabled=1.
    public var needsClear: Bool { isOn || markerExists }
    /// The Mac may be stuck awake and we could not clear it (or a marker is left with nothing in flight).
    public var isStuck: Bool { clearFailed || (!inFlight && !isOn && markerExists) }

    /// Returns false if dropped because a call is already in flight.
    @discardableResult public func set(_ on: Bool) -> Bool {
        guard !inFlight else { return false }
        if on {
            if isOn { return true }
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        } else if !needsClear { return true }
        inFlight = true
        run(on) { [weak self] ok in
            guard let self else { return }
            self.inFlight = false
            if on {
                if ok { self.isOn = true } else { try? FileManager.default.removeItem(at: self.marker) }
            } else if ok {
                self.isOn = false; self.clearFailed = false
                try? FileManager.default.removeItem(at: self.marker)
            } else { self.clearFailed = true }
            self.onIdle?()
        }
        return true
    }

    /// Terminate path: clear synchronously, ignoring in-flight state. Marker removed only on success.
    public func clearBlocking(_ runBlocking: (Bool) -> Bool) {
        guard needsClear else { return }
        if runBlocking(false) {
            isOn = false; clearFailed = false
            try? FileManager.default.removeItem(at: marker)
        } else { clearFailed = true }
    }
}
