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
    /// First letter or digit of the repo, uppercased ("?" when there is none).
    public let glyph: String

    /// "teal diamond R", for VoiceOver and tests.
    public var spoken: String { "\(Self.colourNames[colour]) \(shape.name) \(glyph)" }

    /// For previews (the gallery's sheet of every mark).
    public init(colour: Int, shape: Shape, glyph: String) { self.colour = colour; self.shape = shape; self.glyph = glyph }

    init(slot: Int, repo: String) {
        let s = ((slot % Self.slotCount) + Self.slotCount) % Self.slotCount
        colour = s % Self.colourCount
        shape = Shape(rawValue: s / Self.colourCount) ?? .circle
        glyph = repo.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }
}

/// Hands out identities: the repo's hash picks a preferred slot (same repo, same identity across launches), and when another
/// known repo already holds it the next free slot is used, so repos seen together differ. An assignment is remembered for
/// the life of the process, so a repo never changes look while the app runs. Past `slotCount` repos, slots are shared.
public final class IdentityBook {
    private let lock = NSLock()
    private var slots: [String: Int] = [:]

    public init() {}

    public func identity(for label: RepoLabel) -> SessionIdentity { identity(repo: label.repo) }

    public func identity(repo: String) -> SessionIdentity {
        lock.lock(); defer { lock.unlock() }
        if let s = slots[repo] { return SessionIdentity(slot: s, repo: repo) }
        var pick = Int(Self.fnv1a(repo) % UInt64(SessionIdentity.slotCount))
        if slots.count < SessionIdentity.slotCount {
            let taken = Set(slots.values)
            while taken.contains(pick) { pick = (pick + 1) % SessionIdentity.slotCount }
            slots[repo] = pick
        }
        return SessionIdentity(slot: pick, repo: repo)
    }

    /// Stable across launches (Swift's own hashValue is seeded per process).
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
