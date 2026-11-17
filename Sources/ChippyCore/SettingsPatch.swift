import Foundation

/// Inserts chippy-hook entries into settings.json text without re-serializing the file, so the user's
/// key order, spacing and everything else stay byte-for-byte. Returns nil when the layout is one we
/// can't patch safely; the caller then falls back to a full re-render.
extension SettingsInstaller {
    public static func patched(_ text: String, binary: String, events: [String] = hookEvents,
                               approvalTimeout: Int = defaultApprovalTimeout) -> String? {
        var cur = Array(text.utf8)
        let crlf = usesCRLF(cur)
        for ev in events {
            guard let next = insert(into: cur, event: ev, binary: binary, approvalTimeout: approvalTimeout, crlf: crlf) else { return nil }
            cur = next
        }
        return String(decoding: cur, as: UTF8.self)
    }

    /// Keys that appear more than once in the top-level object or in its `hooks` object (decoded, so
    /// `"\u0068ooks"` counts as `hooks`). Claude Code reads the last duplicate, so the installer refuses these files.
    public static func duplicateKeys(_ text: String) -> [String] {
        let b = Array(text.utf8)
        guard let root = parseObject(b, at: ws(b, 0)) else { return [] }
        var out: [String] = []
        func dups(_ o: Obj) {
            var seen = Set<String>()
            for m in o.members where !seen.insert(m.key).inserted && !out.contains(m.key) { out.append(m.key) }
        }
        dups(root)
        for m in root.members where m.key == "hooks" {
            if let h = parseObject(b, at: m.valStart) { dups(h) }
        }
        return out
    }

    /// True when `eventValue` (the parsed array under one hook event) already holds a hook whose `command`
    /// runs chippy-hook. Looks at hook objects' `command` only, never other fields such as a description.
    public static func hasChippyHook(_ eventValue: Any?) -> Bool {
        guard let entries = eventValue as? [Any] else { return false }
        return entries.contains { entry in
            ((entry as? [String: Any])?["hooks"] as? [Any] ?? []).contains {
                (($0 as? [String: Any])?["command"] as? String)?.contains("chippy-hook") == true
            }
        }
    }

    private static func usesCRLF(_ b: [UInt8]) -> Bool {
        guard let nl = b.firstIndex(of: 10) else { return false }
        return nl > 0 && b[nl - 1] == 13
    }

    // MARK: scanner

    private struct Member { var key: String; var keyStart: Int; var valStart: Int; var valEnd: Int }
    private struct Obj { var open: Int; var close: Int; var members: [Member] }

    private static func ws(_ b: [UInt8], _ i: Int) -> Int {
        var i = i
        while i < b.count, [32, 9, 10, 13].contains(b[i]) { i += 1 }
        return i
    }

    private static func skipString(_ b: [UInt8], _ i: Int) -> Int? {
        guard i < b.count, b[i] == 34 else { return nil }
        var i = i + 1
        while i < b.count {
            if b[i] == 92 { i += 2; continue }
            if b[i] == 34 { return i + 1 }
            i += 1
        }
        return nil
    }

    private static func skipValue(_ b: [UInt8], _ i: Int) -> Int? {
        let i = ws(b, i)
        guard i < b.count else { return nil }
        switch b[i] {
        case 34: return skipString(b, i)
        case 123, 91:
            var depth = 0, j = i
            while j < b.count {
                if b[j] == 34 { guard let e = skipString(b, j) else { return nil }; j = e; continue }
                if b[j] == 123 || b[j] == 91 { depth += 1 }
                if b[j] == 125 || b[j] == 93 { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return nil
        default:
            var j = i
            while j < b.count, ![44, 125, 93, 32, 9, 10, 13].contains(b[j]) { j += 1 }
            return j > i ? j : nil
        }
    }

    private static func parseObject(_ b: [UInt8], at open: Int) -> Obj? {
        guard open < b.count, b[open] == 123 else { return nil }
        var i = ws(b, open + 1)
        var members: [Member] = []
        while i < b.count, b[i] != 125 {
            guard let ke = skipString(b, i) else { return nil }
            let key = (try? JSONSerialization.jsonObject(with: Data(b[i..<ke]), options: .fragmentsAllowed)) as? String
                ?? String(decoding: b[(i + 1)..<(ke - 1)], as: UTF8.self)
            var j = ws(b, ke)
            guard j < b.count, b[j] == 58 else { return nil }
            j = ws(b, j + 1)
            guard let ve = skipValue(b, j) else { return nil }
            members.append(Member(key: key, keyStart: i, valStart: j, valEnd: ve))
            i = ws(b, ve)
            if i < b.count, b[i] == 44 { i = ws(b, i + 1) }
        }
        guard i < b.count else { return nil }
        return Obj(open: open, close: i, members: members)
    }

    /// Whitespace at the start of the line containing `i`.
    private static func lineIndent(_ b: [UInt8], _ i: Int) -> String? {
        var s = i
        while s > 0, b[s - 1] != 10 { s -= 1 }
        guard s > 0 else { return nil }          // same line as the start of file: single-line layout
        var e = s
        while e < b.count, b[e] == 32 || b[e] == 9 { e += 1 }
        return e == i ? String(decoding: b[s..<e], as: UTF8.self) : nil // key must be first on its line
    }

    // MARK: edit

    private static func jsonString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    private static func entryText(event: String, binary: String, approvalTimeout: Int, indent: String, unit: String) -> String {
        let permission = event == "PermissionRequest"
        let cmd = jsonString(command(for: binary, approvalTimeout: permission ? approvalTimeout : nil))
        let hook = "{ \"type\": \"command\", \"command\": \(cmd)" + (permission ? ", \"timeout\": \(approvalTimeout + 10) }" : " }")
        return ["{", "\(unit)\"matcher\": \"*\",", "\(unit)\"hooks\": [", "\(unit)\(unit)\(hook)", "\(unit)]", "}"]
            .enumerated().map { $0.offset == 0 ? $0.element : indent + $0.element }.joined(separator: "\n")
    }

    private static func splice(_ b: [UInt8], _ range: Range<Int>, _ s: String, crlf: Bool) -> [UInt8] {
        let s = crlf ? s.replacingOccurrences(of: "\n", with: "\r\n") : s
        return Array(b[..<range.lowerBound]) + Array(s.utf8) + Array(b[range.upperBound...])
    }

    private static func insertMember(_ b: [UInt8], into o: Obj, key: String, value: (String) -> String, unit: String, baseIndent: String, crlf: Bool) -> [UInt8]? {
        if let first = o.members.first {
            guard let ind = lineIndent(b, first.keyStart) else { return nil }
            let at = o.members.last!.valEnd
            return splice(b, at..<at, ",\n\(ind)\(jsonString(key)): \(value(ind))", crlf: crlf)
        }
        let ind = baseIndent + unit
        return splice(b, (o.open + 1)..<o.close, "\n\(ind)\(jsonString(key)): \(value(ind))\n\(baseIndent)", crlf: crlf)
    }

    private static func insert(into b: [UInt8], event: String, binary: String, approvalTimeout: Int, crlf: Bool) -> [UInt8]? {
        guard let rootStart = Optional(ws(b, 0)), let root = parseObject(b, at: rootStart) else { return nil }
        let unit: String = {
            if let f = root.members.first, let ind = lineIndent(b, f.keyStart), !ind.isEmpty { return ind }
            return "  "
        }()
        func entry(_ ind: String) -> String { entryText(event: event, binary: binary, approvalTimeout: approvalTimeout, indent: ind, unit: unit) }

        guard let hooksMember = root.members.first(where: { $0.key == "hooks" }) else {
            return insertMember(b, into: root, key: "hooks", value: { ind in
                "{\n\(ind)\(unit)\(jsonString(event)): [\n\(ind)\(unit)\(unit)\(entry(ind + unit + unit))\n\(ind)\(unit)]\n\(ind)}"
            }, unit: unit, baseIndent: "", crlf: crlf)
        }
        guard let hooks = parseObject(b, at: hooksMember.valStart) else { return nil }
        let hooksIndent = lineIndent(b, hooksMember.keyStart) ?? ""

        guard let evMember = hooks.members.first(where: { $0.key == event }) else {
            return insertMember(b, into: hooks, key: event, value: { ind in
                "[\n\(ind)\(unit)\(entry(ind + unit))\n\(ind)]"
            }, unit: unit, baseIndent: hooksIndent, crlf: crlf)
        }
        // Event exists: already ours -> nothing to do; else append to its array.
        guard let evValue = try? JSONSerialization.jsonObject(with: Data(b[evMember.valStart..<evMember.valEnd]), options: .fragmentsAllowed) else { return nil }
        if hasChippyHook(evValue) { return b }
        guard b[evMember.valStart] == 91 else { return nil }
        let arrClose = evMember.valEnd - 1
        var lastEnd: Int? = nil, firstStart: Int? = nil
        var i = ws(b, evMember.valStart + 1)
        while i < arrClose {
            guard let e = skipValue(b, i) else { return nil }
            if firstStart == nil { firstStart = i }
            lastEnd = e
            i = ws(b, e)
            if i < b.count, b[i] == 44 { i = ws(b, i + 1) }
        }
        guard let le = lastEnd, let fs = firstStart, let ind = lineIndent(b, fs) else {
            if lastEnd == nil { // empty array
                let evIndent = lineIndent(b, evMember.keyStart) ?? hooksIndent + unit
                let ind = evIndent + unit
                return splice(b, (evMember.valStart + 1)..<arrClose, "\n\(ind)\(entry(ind))\n\(evIndent)", crlf: crlf)
            }
            return nil
        }
        return splice(b, le..<le, ",\n\(ind)\(entry(ind))", crlf: crlf)
    }
}
