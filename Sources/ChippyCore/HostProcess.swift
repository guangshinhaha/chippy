import Foundation

/// Runs a host's CLI for the exact-target step (#136). It ends when the PROCESS exits, never when stdout closes: a child the CLI
/// left running can hold the pipe open for as long as it likes. A process still running at `timeout` is terminated.
/// Blocks the calling thread; call it off the main thread.
public enum HostProcess {
    public static let defaultTimeout: TimeInterval = 5

    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = defaultTimeout) -> OrcaCLI.Select {
        let p = Process()
        let out = Pipe()
        p.executableURL = executable
        p.arguments = arguments
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        guard (try? p.run()) != nil else { return .failed("could not run the host CLI") }

        // Collect what the CLI writes as it writes it; the answer is a line of JSON, so a cap keeps a runaway one small.
        let lock = NSLock()
        var data = Data()
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock(); if data.count < 65_536 { data.append(chunk) }; lock.unlock()
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 1) }
        }
        reader.readabilityHandler = nil
        if timedOut { return .failed("timed out") }
        // Whatever the process wrote before it exited may not have been delivered yet: take it without waiting for EOF.
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            lock.lock(); if data.count < 65_536 { data.append(contentsOf: buf[0..<n]) }; lock.unlock()
        }
        lock.lock(); let answer = data; lock.unlock()
        guard p.terminationReason == .exit else { return .failed("exit \(p.terminationStatus)") }
        return OrcaCLI.interpret(exitStatus: p.terminationStatus, stdout: answer)
    }
}
