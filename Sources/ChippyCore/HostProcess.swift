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

        // One reader, this thread: poll the pipe in short slices and check for exit between them. Nothing else touches the fd,
        // so no chunk can be split, lost or read twice. Non-blocking, so a child holding the pipe open cannot park us.
        let fd = out.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var eof = false
        /// Reads what is there right now. Returns after the pipe is empty (or at EOF).
        func drain() {
            while !eof {
                let n = read(fd, &buf, buf.count)
                if n > 0 { if data.count < 65_536 { data.append(contentsOf: buf[0..<n]) } }
                else if n == 0 { eof = true }
                else if errno != EINTR { return } // EAGAIN: nothing more right now
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while true {
            if exited.wait(timeout: .now()) == .success { break }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { timedOut = true; break }
            if eof { // every writer closed: nothing to poll, just wait for the exit
                if exited.wait(timeout: .now() + left) == .success { break }
                timedOut = true; break
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&pfd, 1, Int32(min(left, 0.05) * 1000))
            drain()
        }
        if timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 1) }
            return .failed("timed out")
        }
        drain() // what it wrote just before it exited
        guard p.terminationReason == .exit else { return .failed("exit \(p.terminationStatus)") }
        return OrcaCLI.interpret(exitStatus: p.terminationStatus, stdout: data)
    }
}
