import Darwin
import Foundation

public enum SocketError: Error {
    case failed(String)
    /// Another process is already listening on the path (#176).
    public static let alreadyRunning = SocketError.failed("already running")
    public var isAlreadyRunning: Bool { if case .failed("already running") = self { return true } else { return false } }
}

private func makeAddr(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError.failed("path too long") }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = b }
        buf[bytes.count] = 0
    }
    return addr
}

private func newSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.failed("socket: \(errno)") }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// What `readLineBounded` found.
enum LineRead: Equatable {
    case line(Data)
    case none      // EOF or timeout before any complete line or data
    case tooLong   // more than `maxBytes` without a newline (#179)
}

/// Blocking read of one newline-terminated line. Returns nil on EOF/timeout before any data.
public func readLine(fd: Int32) -> Data? {
    if case .line(let d) = readLineBounded(fd: fd) { return d }
    return nil
}

/// `readLine` with limits (#179). `maxBytes` caps the line; with `within`, the whole read shares one deadline (a `poll` before
/// each `read`), so a client trickling bytes cannot keep resetting a per-`read` timeout. Hitting the deadline gives `.none`.
func readLineBounded(fd: Int32, maxBytes: Int = .max, within seconds: TimeInterval? = nil) -> LineRead {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    let deadline = seconds.map { DispatchTime.now().uptimeNanoseconds + UInt64(max($0, 0) * 1e9) }
    while true {
        if let deadline {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .none }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(min((deadline - now) / 1_000_000 + 1, 60_000))
            let r = poll(&pfd, 1, ms)
            if r == 0 || (r < 0 && errno == EINTR) { continue } // loop re-checks the deadline
            if r < 0 { return .none }
        }
        let n = read(fd, &buf, buf.count)
        if n <= 0 { return data.isEmpty ? .none : .line(data) }
        let nl = buf[0..<n].firstIndex(of: 10)
        if data.count + (nl ?? n) > maxBytes { return .tooLong }
        if let nl { data.append(contentsOf: buf[0..<nl]); return .line(data) }
        data.append(contentsOf: buf[0..<n])
    }
}

/// Writes `data` plus a newline. True only when every byte went out; false on error or a send timeout (SO_SNDTIMEO).
/// With `within`, the whole line shares one deadline (#177): before each `write` the send timeout is set to the time left
/// (at least 1 ms, since 0 means "no timeout"), and it returns false once the deadline has passed.
public func writeLine(fd: Int32, _ data: Data, within seconds: TimeInterval? = nil) -> Bool {
    var out = data; out.append(10)
    let deadline = seconds.map { DispatchTime.now().uptimeNanoseconds + UInt64(max($0, 0) * 1e9) }
    return out.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                let us = max(Int((deadline - now) / 1000), 1000)
                var snd = timeval(tv_sec: us / 1_000_000, tv_usec: Int32(us % 1_000_000))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))
            }
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

/// Client side (used by chippy-hook). Fails immediately if no listener: ENOENT / ECONNREFUSED.
public enum SocketClient {
    public static func connect(path: String = ChippyPaths.socket) -> Int32? {
        guard let fd = try? newSocket(), var addr = try? makeAddr(path) else { return nil }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }
}

/// One accepted connection. `respond` writes an optional reply line and closes; call it exactly once.
public final class Connection {
    public let fd: Int32
    private var closed = false
    private let lock = NSLock()
    /// The most `respond` may spend writing a reply (#178). It runs on the main thread and holds `lock`, which `peerGone` and `sweep` wait on, so a hook that is alive but stopped (Ctrl-Z) can stall Chippy for this long and no longer.
    static let replyDeadline: TimeInterval = 1
    init(fd: Int32) { self.fd = fd }

    /// A connection to nowhere, for the static gallery render (no relay on the other end).
    public static func detached() -> Connection {
        var fds: [Int32] = [-1, -1]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) // the peer end stays open (one short-lived render process), so a write never hits SIGPIPE
        return Connection(fd: fds[0])
    }

    public func respond(_ reply: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if let reply { _ = writeLine(fd: fd, reply, within: Connection.replyDeadline) } // false: the peer is gone or stuck; nothing more to do but close
        close(fd)
    }

    /// True once the peer hung up (e.g. the hook was killed because the terminal answered).
    public var peerGone: Bool {
        lock.lock(); defer { lock.unlock() }
        if closed { return true }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 0) > 0 else { return false }
        var b: UInt8 = 0
        return recv(fd, &b, 1, MSG_PEEK) <= 0
    }
}

public final class SocketServer {
    public typealias Handler = (Data, Connection) -> Void
    private let path: String
    private let handler: Handler
    private var listenFd: Int32 = -1
    /// Device and inode of the file this server bound, so `stop()` never unlinks a socket another process put there (#176).
    private var bound: (dev: dev_t, ino: ino_t)?
    private var source: DispatchSourceRead?
    private var suspended = false // only touched on `queue`
    private let queue = DispatchQueue(label: "chippy.socket.accept")
    private let workers = DispatchQueue(label: "chippy.socket.workers", attributes: .concurrent)
    /// Longest line a client may send (#179). Past it the connection is answered with `respond(nil)` and closed.
    static let maxLineBytes = 16 * 1024 * 1024
    /// Total time a client has to send its line (#179); trickling bytes does not extend it.
    static let readDeadline: TimeInterval = 5
    /// How long accepting pauses when the process is out of fds (EMFILE/ENFILE), so waiting connections stay queued instead of each failed `accept` dropping one.
    static let acceptBackoff: TimeInterval = 0.5

    public init(path: String = ChippyPaths.socket, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        if let live = SocketClient.connect(path: path) { close(live); throw SocketError.alreadyRunning } // a live listener owns the path: leave it alone
        unlink(path) // no listener: a stale file from a crash, safe to replace
        let fd = try newSocket()
        var addr = try makeAddr(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); throw SocketError.failed("bind: \(errno)") }
        chmod(path, 0o600)
        var st = stat()
        if stat(path, &st) == 0 { bound = (st.st_dev, st.st_ino) }
        guard listen(fd, 16) == 0 else { close(fd); throw SocketError.failed("listen: \(errno)") }
        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        source = src
        src.resume()
    }

    public func stop() {
        queue.sync { // a suspended source must be resumed before it is cancelled and released
            if suspended { source?.resume(); suspended = false }
            source?.cancel(); source = nil
        }
        if listenFd >= 0 { close(listenFd); listenFd = -1 }
        var st = stat()
        if let bound, stat(path, &st) == 0, st.st_dev == bound.dev, st.st_ino == bound.ino { unlink(path) }
        bound = nil
    }

    private func accept() {
        let cfd = Darwin.accept(listenFd, nil, nil)
        guard cfd >= 0 else {
            if (errno == EMFILE || errno == ENFILE), let source, !suspended {
                suspended = true
                source.suspend()
                queue.asyncAfter(deadline: .now() + SocketServer.acceptBackoff) { [weak self] in
                    guard let self, self.suspended else { return }
                    self.suspended = false
                    self.source?.resume()
                }
            }
            return
        }
        var one: Int32 = 1
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        workers.async { [handler] in
            let conn = Connection(fd: cfd)
            // One deadline for the whole line: a client that sends nothing, or trickles, can't hold a worker (#179).
            guard case .line(let line) = readLineBounded(fd: cfd, maxBytes: SocketServer.maxLineBytes, within: SocketServer.readDeadline) else { conn.respond(nil); return }
            handler(line, conn)
        }
    }
}
