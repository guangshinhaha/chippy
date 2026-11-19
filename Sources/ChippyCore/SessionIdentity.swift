import Foundation

/// A stable per-repo identity (#89): a colour slot, a shape and a letter, so no session is told apart by colour alone.
/// Keyed on the RESOLVED repo (`RepoLabel.repo`); a worktree is a sub-label and never changes it. Pure: no UI types here.
public struct SessionIdentity: Equatable {
    public enum Shape: Int, CaseIterable {
        case circle, square, diamond, triangle
        public var name: String { ["circle", "square", "diamond", "triangle"][rawValue] }
    }
    public static let colourNames = ["sky", "green", "yellow", "pink", "violet", "teal", "lime", "blue"]
    public static var colourCount: Int { colourNames.count }
    public static var slotCount: Int { colourCount * Shape.allCases.count }

    /// Index into the app's palette, 0..<colourCount.
    public let colour: Int
    public let shape: Shape
    /// First letter or digit of the uppercased repo; "#" when there is none.
    public let glyph: String

    /// "teal diamond R", for VoiceOver and tests.
    public var spoken: String { "\(spokenShort) \(glyph)" }
    /// "teal diamond": colour and shape only, for places that already say the repo name.
    public var spokenShort: String { "\(Self.colourNames[colour]) \(shape.name)" }

    /// The glyph for a repo name: leading separators and symbols are skipped, then the first Character of the uppercased
    /// remainder is used when it is a letter or digit ("ßtool" gives "S", "élan" gives "É"; "" and "🚀" give "#").
    static func glyph(for repo: String) -> String {
        guard let first = repo.first(where: { $0.isLetter || $0.isNumber }), let c = String(first).uppercased().first,
              c.isLetter || c.isNumber else { return "#" }
        return String(c)
    }

    /// For previews (the gallery's sheet of every mark).
    public init(colour: Int, shape: Shape, glyph: String) { self.colour = colour; self.shape = shape; self.glyph = glyph }

    init(slot: Int, repo: String) {
        let s = ((slot % Self.slotCount) + Self.slotCount) % Self.slotCount
        colour = s % Self.colourCount
        shape = Shape(rawValue: s / Self.colourCount) ?? .circle
        glyph = Self.glyph(for: repo)
    }
}

/// Hands out identities: the repo's hash picks a preferred slot, and when another live repo already holds it the next free
/// slot is used, so repos seen together differ. "Same repo, same identity across launches" holds only absent collisions:
/// a collision-moved repo's slot depends on which repos were seen first.
/// Only RESOLVED repos are stored (an unresolved folder-name fallback would flip when the git label arrives): an unresolved
/// repo gets its raw hash slot, unstored. At `slotCount` live repos the least recently used entry is evicted.
public final class IdentityBook {
    private let lock = NSLock()
    private var slots: [String: Int] = [:]
    private var lastUse: [String: Int] = [:]
    private var clock = 0

    public init() {}

    /// Live (stored) slots, for tests.
    var count: Int { lock.lock(); defer { lock.unlock() }; return slots.count }
    func knows(_ repo: String) -> Bool { lock.lock(); defer { lock.unlock() }; return slots[repo] != nil }

    public func identity(for label: RepoLabel, resolved: Bool = true) -> SessionIdentity { identity(repo: label.repo, resolved: resolved) }

    public func identity(repo: String, resolved: Bool = true) -> SessionIdentity {
        lock.lock(); defer { lock.unlock() }
        clock += 1
        if let s = slots[repo] { lastUse[repo] = clock; return SessionIdentity(slot: s, repo: repo) }
        var pick = Int(Self.fnv1a(repo) % UInt64(SessionIdentity.slotCount))
        guard resolved else { return SessionIdentity(slot: pick, repo: repo) }
        if slots.count >= SessionIdentity.slotCount, let lru = lastUse.min(by: { $0.value < $1.value })?.key {
            slots[lru] = nil; lastUse[lru] = nil
        }
        let taken = Set(slots.values)
        while taken.contains(pick) { pick = (pick + 1) % SessionIdentity.slotCount }
        slots[repo] = pick; lastUse[repo] = clock
        return SessionIdentity(slot: pick, repo: repo)
    }

    /// Stable across launches (Swift's own hashValue is seeded per process).
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
