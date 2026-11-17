import Foundation

public enum ChippyPaths {
    /// ~/Library/Application Support/Chippy (override with CHIPPY_HOME for tests).
    public static var supportDir: URL {
        if let h = ProcessInfo.processInfo.environment["CHIPPY_HOME"] { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Chippy")
    }
    public static var socket: String {
        if let s = ProcessInfo.processInfo.environment["CHIPPY_SOCKET"] { return s }
        return supportDir.appendingPathComponent("chippy.sock").path
    }
}
