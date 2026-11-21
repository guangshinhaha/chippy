import XCTest
@testable import ChippyCore

/// A reply to a stopped (alive but not reading) hook must not hold up Chippy's main thread (#178).
final class ConnectionReplyTests: XCTestCase {
    private func pair() -> (Connection, peer: Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (Connection(fd: fds[0]), fds[1])
    }

    /// Runs `respond` off the test thread so a regression fails after 1.5s instead of hanging the suite. Returns the seconds it took, nil if still blocked.
    private func timedRespond(_ conn: Connection, _ reply: Data) -> TimeInterval? {
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        DispatchQueue.global().async { conn.respond(reply); done.signal() }
        return done.wait(timeout: .now() + 1.5) == .success ? Date().timeIntervalSince(start) : nil
    }

    func testRespondToNeverReadingPeerReturnsWithinDeadlineAndClosesFd() {
        let (conn, peer) = pair()
        defer { close(peer) } // also unblocks a regressed write so the worker thread can finish
        let took = timedRespond(conn, Data(repeating: 0x61, count: 64 * 1024))
        XCTAssertNotNil(took, "respond blocked past 1.5s on a peer that never reads")
        XCTAssertEqual(fcntl(conn.fd, F_GETFD), -1, "the fd must be closed after respond")
        XCTAssertEqual(errno, EBADF)
    }

    func testPeerGoneAndSecondRespondAreNotHeldByAStuckReply() {
        let (conn, peer) = pair()
        defer { close(peer) }
        let writer = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { conn.respond(Data(repeating: 0x62, count: 64 * 1024)); writer.signal() }
        Thread.sleep(forTimeInterval: 0.2) // the write is now stuck holding the lock
        let probe = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = conn.peerGone; probe.signal() } // waits on the same lock as the write
        XCTAssertEqual(probe.wait(timeout: .now() + 1.5), .success, "peerGone must wait no longer than the write deadline")
        XCTAssertEqual(writer.wait(timeout: .now() + 2), .success)
    }

    func testSmallReplyStillDelivered() {
        let (conn, peer) = pair()
        defer { close(peer) }
        conn.respond(Data("{\"ok\":true}".utf8))
        XCTAssertEqual(readLine(fd: peer), Data("{\"ok\":true}".utf8))
    }
}
