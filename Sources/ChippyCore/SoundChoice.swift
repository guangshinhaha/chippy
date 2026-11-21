import Foundation

/// Which macOS system sound plays for each kind (#163). Pure: the app passes in what is installed and what was saved.
/// An empty, unknown or not-installed saved name gives the kind's default.
public enum SoundChoice {
    public static func defaultName(_ kind: SoundKind) -> String { kind == .needsYou ? "Pop" : "Tink" }

    public static func key(_ kind: SoundKind) -> String { kind == .needsYou ? "sounds.name.needsYou" : "sounds.name.done" }

    public static func name(for kind: SoundKind, saved: String?, installed: [String]) -> String {
        guard let s = saved, !s.isEmpty, installed.contains(s) else { return defaultName(kind) }
        return s
    }

    public static func name(for kind: SoundKind, defaults: UserDefaults, installed: [String]) -> String {
        name(for: kind, saved: defaults.string(forKey: key(kind)), installed: installed)
    }

    /// Sound names from the file names in a system sounds folder: `.aiff` only, sorted, without the extension.
    public static func installedNames(fromFiles files: [String]) -> [String] {
        files.filter { $0.hasSuffix(".aiff") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) }.sorted()
    }
}
