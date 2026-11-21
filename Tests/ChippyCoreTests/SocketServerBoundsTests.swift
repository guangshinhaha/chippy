import Darwin
import XCTest
@testable import ChippyCore

/// The socket server stays bounded under an oversized line, a trickling client and a full fd table (#179).
final class SocketServerBoundsTests: XCTestCase {
    private func connectedClient(_ path: String) throws -> Int32 {
        try XCTUnwrap(SocketClient.connect(path: path))
    }

    private func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(ru.ru_utime) + s(ru.ru_stime)
    }

    /// A client streaming past the server's line cap with no newline is cut off, and the handler never sees it.
    func testOversizeLineIsClosedAndHandlerNeverCalled() throws {
        let path = scratchURL("chippy-\(getpid())o.sock").path
        let called = NSLock(); var calls = 0
        let server = SocketServer(path: path) { _, conn in called.lock(); calls += 1; called.unlock(); conn.respond(nil) }
        try server.start()
        defer { server.stop() }
        let fd = try connectedClient(path)
        defer { close(fd) }
        var snd = timeval(tv_sec: 3, tv_usec: 0) // a regressed server can't hang the test: the write gives up
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))
        let chunk = [UInt8](repeating: 0x61, count: 1 << 20)
        var sent = 0, failed = false
        for _ in 0..<24 { // 24 MB, well past the 16 MB cap
            let n = write(fd, chunk, chunk.count)
            if n != chunk.count { failed = true; break }
            sent += n
        }
        XCTAssertTrue(failed, "the server kept reading all \(sent) bytes")
        // The server closed its end: the client reads EOF (or a reset), not a reply.
        var b: UInt8 = 0
        XCTAssertLessThanOrEqual(read(fd, &b, 1), 0)
        Thread.sleep(forTimeInterval: 0.3)
        called.lock(); defer { called.unlock() }
        XCTAssertEqual(calls, 0, "the handler must not run for an oversize line")
    }

    /// 1 byte every 1.5s used to reset the per-read timeout forever; the total deadline (5s) closes it.
    func testTrickleClientIsClosedWithinReadDeadline() throws {
        let path = scratchURL("chippy-\(getpid())t.sock").path
        let called = NSLock(); var calls = 0
        let server = SocketServer(path: path) { _, conn in called.lock(); calls += 1; called.unlock(); conn.respond(nil) }
        try server.start()
        defer { server.stop() }
        let fd = try connectedClient(path)
        defer { close(fd) }
        let start = Date()
        var closedAt: TimeInterval?
        var byte: UInt8 = 0x61
        while closedAt == nil, Date().timeIntervalSince(start) < 9 { // hard cap: a regressed server fails, never hangs
            if write(fd, &byte, 1) != 1 { closedAt = Date().timeIntervalSince(start); break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 1500) > 0, recv(fd, &byte, 1, MSG_PEEK) <= 0 { closedAt = Date().timeIntervalSince(start) }
        }
        let t = try XCTUnwrap(closedAt, "still held open after 9s of trickling")
        XCTAssertLessThan(t, 6.5, "closed at \(t)s, the deadline is 5s")
        XCTAssertGreaterThan(t, 3, "closed at \(t)s: too early to be the total deadline")
        called.lock(); defer { called.unlock() }
        XCTAssertEqual(calls, 0)
    }

    private func rawSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func rawConnect(_ fd: Int32, _ path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in path.utf8.enumerated() { buf[i] = b }; buf[path.utf8.count] = 0 }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }

    /// Runs `body` with this process's fd table full: RLIMIT_NOFILE is lowered to the open fds plus `clients` unconnected
    /// sockets (made first, since `connect` needs no new fd) and every spare slot is filled. Tests run serially; the limit
    /// is restored by `release()`, by a defer, and by a 6s watchdog thread, so a stalled or failing body cannot leave the
    /// process starved. `release` is idempotent.
    private func withFdTableFull(clients n: Int, _ body: (_ clients: [Int32], _ release: () -> Void) -> Void) {
        var old = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &old), 0)
        var maxOpen: Int32 = 2
        for fd in 0..<Int32(min(old.rlim_cur, 10_240)) where fcntl(fd, F_GETFD) != -1 { maxOpen = fd }
        let clients = (0..<n).map { _ in rawSocket() }
        var fillers: [Int32] = []
        var released = false
        let lock = NSLock()
        func release() {
            lock.lock(); defer { lock.unlock() }
            guard !released else { return }
            released = true
            var o = old; setrlimit(RLIMIT_NOFILE, &o)
            for f in fillers { close(f) }; fillers = []
        }
        defer { release(); for c in clients { close(c) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { // watchdog: restore only (no fd needed); the fillers close in `release` too
            lock.lock(); let was = released; lock.unlock()
            if !was { var o = old; setrlimit(RLIMIT_NOFILE, &o) }
        }
        var low = old; low.rlim_cur = rlim_t(maxOpen) + rlim_t(n) + 2 // exactly one slot free: the filler takes it
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &low), 0)
        while true { let f = open("/dev/null", O_RDONLY); if f < 0 { break }; fillers.append(f) }
        body(clients, release)
    }

    /// With no fd free, accept fails with EMFILE. Held for 2s, the accept loop must not burn CPU.
    /// (On macOS a failed accept also drops the connection it tried to take, so `main` does not actually spin; this guards it.)
    func testFullFdTableKeepsAcceptLoopIdle() throws {
        let path = scratchURL("chippy-\(getpid())f.sock").path
        let server = SocketServer(path: path) { _, conn in conn.respond(nil) }
        try server.start()
        defer { server.stop() }
        var cpu = 1.0
        withFdTableFull(clients: 1) { clients, release in
            XCTAssertTrue(rawConnect(clients[0], path))
            Thread.sleep(forTimeInterval: 0.3) // let the accept loop hit EMFILE
            let cpu0 = cpuSeconds(), wall0 = Date()
            Thread.sleep(forTimeInterval: 2)
            cpu = (cpuSeconds() - cpu0) / Date().timeIntervalSince(wall0)
            release()
        }
        print("fd-table-full accept CPU over 2s: \(Int(cpu * 100))%")
        XCTAssertLessThan(cpu, 0.2, "accept loop used \(Int(cpu * 100))% CPU with the fd table full")
    }

    /// A connection that arrives while accept is failing with EMFILE must wait in the backlog for the 0.5s back-off and be
    /// served once fds free up. On `main` the accept loop retries at once and the failed accept drops it (EPIPE).
    func testConnectionArrivingDuringFdExhaustionIsServedAfterRecovery() throws {
        let path = scratchURL("chippy-\(getpid())g.sock").path
        let lock = NSLock(); var received: Data?
        let got = expectation(description: "handler ran after fds freed")
        let server = SocketServer(path: path) { line, conn in
            lock.lock(); received = line; lock.unlock(); conn.respond(nil); got.fulfill()
        }
        try server.start()
        defer { server.stop() }
        var wrote = false
        withFdTableFull(clients: 2) { clients, release in
            XCTAssertTrue(rawConnect(clients[0], path)) // accept fails on this one: EMFILE, the server backs off
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertTrue(rawConnect(clients[1], path)) // arrives during the back-off
            Thread.sleep(forTimeInterval: 0.05)
            release()
            wrote = writeLine(fd: clients[1], Data("hello".utf8))
        }
        XCTAssertTrue(wrote, "the connection was dropped while fds were exhausted")
        wait(for: [got], timeout: 3)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(received, Data("hello".utf8))
    }
}
