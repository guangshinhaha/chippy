import Foundation

/// T3 Code host support (#138). Pure: AppKit opens the URL; this decides what it is.
/// T3 sets `T3CODE_THREAD_ID` in the env of the `claude` process it spawns, and its desktop app opens
/// `t3code://threads/<environmentId>/<threadId>` on that thread. No T3 MCP, RPC or credentials involved.
public enum T3Link {
    public static let bundleId = "com.t3tools.t3code"

    /// The env var T3 sets for the `claude` process it spawns.
    public static let threadEnvName = "T3CODE_THREAD_ID"

    /// Where T3 keeps its environment id, relative to the home folder.
    public static let environmentIdPath = ".t3/userdata/environment-id"

    /// An id from the environment or a file, only if it is safe to put in a URL path: letters, digits, `_` and `-`.
    public static func validId(_ s: String?) -> String? {
        guard let s, s.range(of: "^[A-Za-z0-9_-]{1,128}\\z", options: .regularExpression) != nil else { return nil }
        return s
    }

    /// The environment id file holds one id and a trailing newline.
    public static func environmentId(fileContents: String?) -> String? {
        validId(fileContents?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func url(environmentId: String?, threadId: String?) -> URL? {
        guard let e = validId(environmentId), let t = validId(threadId) else { return nil }
        return URL(string: "t3code://threads/\(e)/\(t)")
    }

    /// The thread to open for this host: only T3 Code, and only when the relay saw a thread id.
    public static func threadId(for host: HostInfo?) -> String? {
        guard let h = host, h.bundle == bundleId else { return nil }
        return validId(h.env[threadEnvName])
    }
}
