import Darwin
import Foundation

public enum SocketError: Error { case failed(String) }

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

/// Blocking read of one newline-terminated line. Returns nil on EOF/timeout before any data.
public func readLine(fd: Int32) -> Data? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { return data.isEmpty ? nil : data }
        if let nl = buf[0..<n].firstIndex(of: 10) {
            data.append(contentsOf: buf[0..<nl]); return data
        }
        data.append(contentsOf: buf[0..<n])
    }
}

public func writeLine(fd: Int32, _ data: Data) {
    var out = data; out.append(10)
    out.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n <= 0 { return }
            off += n
        }
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
    init(fd: Int32) { self.fd = fd }

    public func respond(_ reply: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if let reply { writeLine(fd: fd, reply) }
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
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "chippy.socket.accept")
    private let workers = DispatchQueue(label: "chippy.socket.workers", attributes: .concurrent)

    public init(path: String = ChippyPaths.socket, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)
        let fd = try newSocket()
        var addr = try makeAddr(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); throw SocketError.failed("bind: \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw SocketError.failed("listen: \(errno)") }
        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel(); source = nil
        if listenFd >= 0 { close(listenFd); listenFd = -1 }
        unlink(path)
    }

    private func accept() {
        let cfd = Darwin.accept(listenFd, nil, nil)
        guard cfd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0) // a client that never sends a line can't hold a worker
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        workers.async { [handler] in
            let conn = Connection(fd: cfd)
            guard let line = readLine(fd: cfd) else { conn.respond(nil); return }
            handler(line, conn)
        }
    }
}
