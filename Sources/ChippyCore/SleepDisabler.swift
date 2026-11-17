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
    /// Only fires after a SUCCESSFUL call that dropped a request meanwhile. After a failure the owner's
    /// own timer is the only retry, and `retryFloor` stops it calling more often than that.
    public var onIdle: (() -> Void)?
    public static let retryFloor: TimeInterval = 5

    private let now: () -> Date
    private let pump: (TimeInterval) -> Void
    private var dropped = false
    private var lastFailure: Date?

    public init(marker: URL, now: @escaping () -> Date = Date.init,
                pump: @escaping (TimeInterval) -> Void = { RunLoop.current.run(until: Date().addingTimeInterval($0)) },
                run: @escaping Runner) {
        self.marker = marker; self.now = now; self.pump = pump; self.run = run
    }

    public var markerExists: Bool { FileManager.default.fileExists(atPath: marker.path) }
    /// Something may still be holding SleepDisabled=1.
    public var needsClear: Bool { isOn || markerExists }
    /// The Mac may be stuck awake and we could not clear it (or a marker is left with nothing in flight).
    public var isStuck: Bool { clearFailed || (!inFlight && !isOn && markerExists) }

    /// Returns false if dropped because a call is already in flight.
    @discardableResult public func set(_ on: Bool) -> Bool {
        guard !inFlight else { dropped = true; return false }
        if let f = lastFailure, now().timeIntervalSince(f) < Self.retryFloor { return false }
        if on {
            if isOn { return true }
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        } else if !needsClear { return true }
        inFlight = true
        run(on) { [weak self] ok in
            guard let self else { return }
            self.inFlight = false
            if ok { self.lastFailure = nil } else { self.lastFailure = self.now() }
            if on {
                if ok { self.isOn = true } else { try? FileManager.default.removeItem(at: self.marker) }
            } else if ok {
                self.isOn = false; self.clearFailed = false
                try? FileManager.default.removeItem(at: self.marker)
            } else { self.clearFailed = true }
            let redo = ok && self.dropped
            self.dropped = false
            if redo { self.onIdle?() }
        }
        return true
    }

    /// Terminate / remove-setup path. Waits (bounded, `timeout`) for any in-flight call so a pending `1`
    /// cannot finish after our `0`, then clears synchronously. The marker is removed only if the `0` succeeded
    /// and nothing is still in flight; otherwise it stays so a relaunch recovers.
    public func clearBlocking(timeout: TimeInterval = 3, _ runBlocking: (Bool) -> Bool) {
        let deadline = now().addingTimeInterval(timeout)
        while inFlight, now() < deadline { pump(0.05) }
        guard needsClear else { return }
        if runBlocking(false), !inFlight {
            isOn = false; clearFailed = false
            try? FileManager.default.removeItem(at: marker)
        } else { clearFailed = true }
    }
}
