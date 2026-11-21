import XCTest
@testable import ChippyCore

/// `chippy-hook install` writes the proposed settings to a temp file for `diff`; it must never leave it behind (#182).
final class InstallTempFileTests: XCTestCase {
    private func dir(_ name: String) throws -> URL {
        let d = scratchURL("chippy-182-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func leftovers(_ d: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasPrefix("chippy-settings-") }
    }

    func testProposalFileHasAUniqueNameAndMode0600() throws {
        let d = try dir("tmp")
        let a = try SettingsInstaller.writeProposal(Data("a".utf8), in: d)
        let b = try SettingsInstaller.writeProposal(Data("b".utf8), in: d)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.lastPathComponent.hasPrefix("chippy-settings-"))
        XCTAssertEqual(try Data(contentsOf: a), Data("a".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testProposalDirectoryHonoursTMPDIRWhenItIsAFolder() throws {
        let d = try dir("tmp")
        XCTAssertEqual(SettingsInstaller.proposalDirectory(environment: ["TMPDIR": d.path + "/"]).standardizedFileURL.path, d.standardizedFileURL.path)
        let fallback = FileManager.default.temporaryDirectory
        XCTAssertEqual(SettingsInstaller.proposalDirectory(environment: ["TMPDIR": d.path + "/missing"]), fallback)
        XCTAssertEqual(SettingsInstaller.proposalDirectory(environment: [:]), fallback)
    }

    // MARK: the real binary

    private func hook() throws -> URL {
        let bin = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("chippy-hook")
        return try XCTUnwrap(FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil, "build chippy-hook first: \(bin.path)")
    }

    /// Runs `chippy-hook install --settings <settings> ...` with TMPDIR and HOME pointed at scratch folders.
    private func install(settings: URL, tmp: URL, stdin: String, _ extra: [String] = []) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = try hook()
        p.arguments = ["install", "--settings", settings.path] + extra
        p.environment = ["TMPDIR": tmp.path + "/", "HOME": tmp.path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = outPipe
        try p.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    private func settingsFile(_ d: URL) throws -> URL {
        let f = d.appendingPathComponent("settings.json")
        try Data("{\"model\": \"opus\"}\n".utf8).write(to: f)
        return f
    }

    func testAbortLeavesNoTempFile() throws {
        let work = try dir("work"), tmp = try dir("tmp")
        let r = try install(settings: settingsFile(work), tmp: tmp, stdin: "n\n")
        XCTAssertEqual(r.status, 1, r.out)
        XCTAssertTrue(r.out.contains("Aborted"), r.out)
        XCTAssertEqual(leftovers(tmp), [])
    }

    func testSuccessLeavesNoTempFile() throws {
        let work = try dir("work"), tmp = try dir("tmp")
        let r = try install(settings: settingsFile(work), tmp: tmp, stdin: "", ["--yes"])
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("Installed."), r.out)
        XCTAssertEqual(leftovers(tmp), [])
    }

    func testAlreadyInstalledLeavesNoTempFile() throws {
        let work = try dir("work"), tmp = try dir("tmp")
        let s = try settingsFile(work)
        XCTAssertEqual(try install(settings: s, tmp: tmp, stdin: "", ["--yes"]).status, 0)
        let r = try install(settings: s, tmp: tmp, stdin: "n\n")
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("Already installed"), r.out)
        XCTAssertEqual(leftovers(tmp), [])
    }

    func testBackupFailureLeavesNoTempFile() throws {
        let work = try dir("work"), tmp = try dir("tmp")
        let s = try settingsFile(work)
        // The settings file is readable but its folder is not writable, so the backup copy fails after the temp file exists.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: work.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path) }
        let r = try install(settings: s, tmp: tmp, stdin: "", ["--yes"])
        XCTAssertEqual(r.status, 1, r.out)
        XCTAssertTrue(r.out.contains("backup failed"), r.out)
        XCTAssertEqual(leftovers(tmp), [])
    }

    func testChangedWhileWaitingLeavesNoTempFile() throws {
        let work = try dir("work"), tmp = try dir("tmp")
        let s = try settingsFile(work)
        let p = Process()
        p.executableURL = try hook()
        p.arguments = ["install", "--settings", s.path]
        p.environment = ["TMPDIR": tmp.path + "/", "HOME": tmp.path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = outPipe
        try p.run()
        // Output is buffered on a pipe, so the prompt can't be read. The temp file exists before the prompt: wait for it,
        // edit the settings while install blocks on stdin, then answer y.
        let deadline = Date().addingTimeInterval(10)
        while leftovers(tmp).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(leftovers(tmp).isEmpty, "install never reached the prompt")
        try Data("{\"model\": \"sonnet\"}\n".utf8).write(to: s)
        inPipe.fileHandleForWriting.write(Data("y\n".utf8))
        try? inPipe.fileHandleForWriting.close()
        let seen = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: seen, as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 1, out)
        XCTAssertTrue(out.contains("changed while waiting"), out)
        XCTAssertEqual(leftovers(tmp), [])
    }
}
