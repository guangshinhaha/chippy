import Foundation
import XCTest

extension XCTestCase {
    /// A throwaway `UserDefaults` suite that is gone when the test ends (#172). `removePersistentDomain` empties the
    /// preferences file but leaves it behind, so the file is deleted too. Returns the suite name for a second handle.
    func scratchDefaults(_ prefix: String = "chippy-test") -> (suite: String, defaults: UserDefaults) {
        let suite = "\(prefix)-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            d.removePersistentDomain(forName: suite)
            let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        return (suite, d)
    }
}

extension XCTestCase {
    /// A path in the temp directory that is removed when the test ends (#174). A name with a `/` removes its top folder.
    func scratchURL(_ name: String) -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(name.components(separatedBy: "/")[0])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return tmp.appendingPathComponent(name)
    }
}
