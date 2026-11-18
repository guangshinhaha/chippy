import Foundation

/// One consistent label for a row (#101): the repo, plus the worktree folder only when the cwd is a linked worktree
/// (never for the repo's main checkout). Folder names and pointer files only: no file content is read.
public struct RepoLabel: Equatable {
    public let repo: String
    public let worktree: String?
    public init(repo: String, worktree: String? = nil) { self.repo = repo; self.worktree = worktree }

    /// "repo" or "repo / worktree" (plain text for VoiceOver and tests).
    public var text: String { worktree.map { "\(repo) / \($0)" } ?? repo }
}

public enum RepoResolver {
    /// What to show before (or without) git: a Claude worktree (`<repo>/.claude/worktrees/<x>`) maps to its repo, anything
    /// else to the folder name. `project` is the caller's own best name (used only when the path gives nothing).
    public static func fallback(cwd: String, project: String = "") -> RepoLabel {
        if let r = cwd.range(of: "/.claude/worktrees/") {
            let repo = (String(cwd[..<r.lowerBound]) as NSString).lastPathComponent
            let tail = String(cwd[r.upperBound...]).split(separator: "/").first.map(String.init)
            if !repo.isEmpty { return RepoLabel(repo: repo, worktree: tail) }
        }
        let name = (cwd as NSString).lastPathComponent
        if !cwd.isEmpty, !name.isEmpty, name != "/" { return RepoLabel(repo: name) }
        return RepoLabel(repo: project.isEmpty ? "unknown" : project)
    }

    /// Repo from git without running it: finds the checkout's `.git`; for a linked worktree its pointer file names
    /// `<main>/.git/worktrees/<name>`, so the main worktree's folder is the repo. Blocking file reads: call off the main thread.
    /// Falls back to the folder name (see `fallback`) when there is no git, or the layout is unrecognised.
    public static func resolve(cwd: String, project: String = "") -> RepoLabel {
        let fb = fallback(cwd: cwd, project: project)
        guard cwd.hasPrefix("/") else { return fb }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<12 {
            let dot = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dot.path, isDirectory: &isDir) {
                let root = dir.lastPathComponent
                if isDir.boolValue { return RepoLabel(repo: root) } // main checkout
                guard let t = try? String(contentsOf: dot, encoding: .utf8),
                      let line = t.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return fb }
                let p = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                let gitDir = (p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)).standardizedFileURL
                // Linked worktree: <common>/worktrees/<name>. Anything else (a submodule's .git/modules/x) is its own repo.
                guard gitDir.deletingLastPathComponent().lastPathComponent == "worktrees" else { return RepoLabel(repo: root) }
                let common = gitDir.deletingLastPathComponent().deletingLastPathComponent()
                var repo = common.lastPathComponent == ".git" ? common.deletingLastPathComponent().lastPathComponent : common.lastPathComponent
                if repo.hasSuffix(".git") && repo.count > 4 { repo = String(repo.dropLast(4)) } // bare repo "foo.git"
                guard !repo.isEmpty, repo != "/" else { return fb }
                return RepoLabel(repo: repo, worktree: root == repo ? nil : root)
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
        return fb
    }
}

/// Resolved labels per cwd, so git is read once per folder and never on the main thread (#101). `label` answers at once:
/// the cached label, or the folder-name fallback while a background read runs; `onResolved` fires on the main thread
/// when a label turns out different, so the UI redraws.
public final class RepoIdentityCache {
    private let lock = NSLock()
    private var labels: [String: RepoLabel] = [:]
    private var inflight: Set<String> = []
    private let resolver: (String) -> RepoLabel
    private let background: (@escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    /// Folders kept; past this the cache restarts (a long day of throwaway worktrees must not grow it forever).
    public static let capacity = 256
    public var onResolved: (() -> Void)?

    public init(resolver: @escaping (String) -> RepoLabel = { RepoResolver.resolve(cwd: $0) },
                background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
                deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.resolver = resolver; self.background = background; self.deliver = deliver
    }

    public func label(cwd: String, project: String = "") -> RepoLabel {
        let fb = RepoResolver.fallback(cwd: cwd, project: project)
        guard !cwd.isEmpty else { return fb }
        lock.lock()
        if let hit = labels[cwd] { lock.unlock(); return hit }
        let start = inflight.insert(cwd).inserted
        lock.unlock()
        if start {
            background { [weak self] in
                guard let self else { return }
                let found = self.resolver(cwd)
                self.lock.lock()
                if self.labels.count >= Self.capacity { self.labels.removeAll() }
                self.labels[cwd] = found
                self.inflight.remove(cwd)
                self.lock.unlock()
                if found != fb { self.deliver { [weak self] in self?.onResolved?() } }
            }
        }
        return fb
    }
}
