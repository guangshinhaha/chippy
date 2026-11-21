import Foundation

/// One consistent label for a row (#101): the repo, plus the worktree folder only when the cwd is a linked worktree
/// (never for the repo's main checkout). Folder names and pointer files only: no file content is read.
public struct RepoLabel: Equatable {
    public let repo: String
    public let worktree: String?
    public init(repo: String, worktree: String? = nil) { self.repo = repo; self.worktree = worktree }

    /// "repo" or "repo / worktree" (plain text for VoiceOver and tests).
    public var text: String { worktree.map { "\(repo) / \($0)" } ?? repo }

    /// The worktree tag as shown (#209): the input when it fits in `maxChars` Characters, else a middle-truncated string of
    /// exactly `maxChars` Characters around "…". Counts grapheme clusters, so an emoji is never split. Lets the view size
    /// the tag to its content (`fixedSize`) while the cap bounds how wide it can get.
    public static func worktreeTag(_ s: String, maxChars: Int = 16) -> String {
        let chars = Array(s)
        guard chars.count > maxChars else { return s }
        guard maxChars > 1 else { return maxChars == 1 ? "…" : "" }
        let keep = maxChars - 1
        return String(chars.prefix((keep + 1) / 2)) + "…" + String(chars.suffix(keep / 2))
    }
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
        // A generated folder (a T3 or agent worktree) is not the repo: its parent folder names the repo (#139).
        if !cwd.isEmpty, PanelSections.isHashLike(name) {
            let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !parent.isEmpty, parent != "/" { return RepoLabel(repo: parent) }
        }
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
        // A folder that is gone (deleted worktree) cannot be confirmed by git; walking up would land on the main checkout
        // and drop the worktree tag the path heuristic still knows, so resolve and fallback must agree here.
        guard fm.fileExists(atPath: cwd) else { return fb }
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<12 {
            let dot = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dot.path, isDirectory: &isDir) {
                let root = dir.lastPathComponent
                if isDir.boolValue { // main checkout (a path-heuristic worktree tag survives when git cannot say otherwise)
                    if fb.worktree != nil, fb.repo == root { return fb }
                    if PanelSections.isHashLike(root) { return fb } // a generated folder name is never the repo: stay with the fallback so the label cannot flip (#139)
                    return RepoLabel(repo: root)
                }
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
                // A linked worktree always carries a tag, even when its folder shares the repo's name (~/wt/chippy for ~/orca/chippy).
                if root != repo { return RepoLabel(repo: repo, worktree: root) }
                let parent = dir.deletingLastPathComponent().lastPathComponent
                return RepoLabel(repo: repo, worktree: parent.isEmpty || parent == "/" ? "linked" : "\(parent)/\(root)")
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { break }
            dir = up
        }
        return fb
    }
}

/// Resolved labels per cwd, so git is read once per folder and never on the main thread (#101). `label` answers at once:
/// the cached label, or the folder-name fallback while a background read runs; observers are told on the main thread
/// when a shown label turns out different, so the UI redraws. Entries older than `ttl` are served as-is and re-read in the
/// background, so labels follow a `git init` or a worktree change.
public final class RepoIdentityCache {
    private struct Entry { var label: RepoLabel; var at: Date; var used: Int }
    private let lock = NSLock()
    private var labels: [String: Entry] = [:]
    private var inflight: Set<String> = []
    /// What the latest caller was shown while no resolved label existed (its own fallback), per in-flight cwd.
    private var shownWhileLoading: [String: RepoLabel] = [:]
    /// Bumped on every use; the entry with the lowest `used` is the least recently used.
    private var tick = 0
    private var observers: [() -> Void] = []
    private let resolver: (String) -> RepoLabel
    private let background: (@escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    private let now: () -> Date
    /// Folders kept; at the cap the single least recently used entry makes room (a long day of throwaway worktrees must not grow it forever).
    public static let capacity = 256
    /// How long a label is trusted before a background re-read.
    public static let ttl: TimeInterval = 60

    public init(resolver: @escaping (String) -> RepoLabel = { RepoResolver.resolve(cwd: $0) },
                background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
                deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
                now: @escaping () -> Date = Date.init) {
        self.resolver = resolver; self.background = background; self.deliver = deliver; self.now = now
    }

    /// Several owners may watch one cache (each model, a test); every observer is called, on the main thread.
    public func addObserver(_ f: @escaping () -> Void) { lock.lock(); observers.append(f); lock.unlock() }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return labels.count }

    /// True once a git read has answered for this cwd (an empty cwd never changes, so it counts as final).
    public func isResolved(cwd: String) -> Bool {
        if cwd.isEmpty { return true }
        lock.lock(); defer { lock.unlock() }
        return labels[cwd] != nil
    }

    public func label(cwd: String, project: String = "") -> RepoLabel {
        let fb = RepoResolver.fallback(cwd: cwd, project: project)
        guard !cwd.isEmpty else { return fb }
        let t = now()
        lock.lock()
        let hit = labels[cwd]
        if hit != nil { tick += 1; labels[cwd]?.used = tick }
        let stale = hit.map { t.timeIntervalSince($0.at) >= Self.ttl } ?? true
        let start = stale && inflight.insert(cwd).inserted
        if hit == nil, inflight.contains(cwd) { shownWhileLoading[cwd] = fb }
        lock.unlock()
        if start {
            background { [weak self] in
                guard let self else { return }
                let found = self.resolver(cwd)
                self.lock.lock()
                let shown = self.labels[cwd]?.label ?? self.shownWhileLoading[cwd] ?? fb
                self.shownWhileLoading[cwd] = nil
                if self.labels[cwd] == nil, self.labels.count >= Self.capacity,
                   let oldest = self.labels.min(by: { $0.value.used < $1.value.used })?.key { self.labels[oldest] = nil }
                self.tick += 1
                self.labels[cwd] = Entry(label: found, at: self.now(), used: self.tick)
                self.inflight.remove(cwd)
                let obs = found != shown ? self.observers : []
                self.lock.unlock()
                if !obs.isEmpty { self.deliver { obs.forEach { $0() } } }
            }
        }
        return hit?.label ?? fb
    }
}
