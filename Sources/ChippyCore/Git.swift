import Foundation

/// Reads the current branch straight from `.git/HEAD`: no git process, no command text, nothing leaves the machine.
public enum GitInfo {
    public static func branch(cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<12 {
            let dot = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dot.path, isDirectory: &isDir) {
                var gitDir = dot
                if !isDir.boolValue { // worktree: ".git" is a file "gitdir: <path>"
                    guard let t = try? String(contentsOf: dot, encoding: .utf8),
                          let line = t.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                    let p = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst("ref: refs/heads/".count)) }
                if h.hasPrefix("ref:") { return h.split(separator: "/").last.map(String.init) }
                return h.count >= 7 && h.allSatisfy(\.isHexDigit) ? String(h.prefix(7)) : nil // detached
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return nil }
            dir = up
        }
        return nil
    }
}
