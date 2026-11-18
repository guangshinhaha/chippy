import AppKit
import ChippyCore
import SwiftUI

/// `Chippy --render-gallery out.png` renders every state x density to a PNG, headless.
/// Used as evidence for the state/density acceptance checks.
enum Gallery {
    /// A model with `count` finished chips (one per session), forced to `density`. Build it outside view bodies.
    @MainActor private static func seededModel(count: Int, density: Density, state: ChippyState = .done, cwd: String = "/demo/api-server") -> NotchModel {
        let model = NotchModel(state: state, density: density)
        for i in 0..<count {
            model.apply(HookPayload(json: Data(#"{"session_id":"s\#(i)","hook_event_name":"Stop","cwd":"\#(cwd)","chippy_branch":"main"}"#.utf8))!)
        }
        model.density = density
        return model
    }

    @MainActor private static func box(_ m: NotchMetrics) -> MetricsBox { let b = MetricsBox(); b.metrics = m; return b }

    @MainActor
    static func render(to path: String) {
        // The asleep sample: built once here (isolated store/log), a quiet session. No side effects in the view body.
        let sleepy = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("gal-sleep.jsonl")))
        sleepy.apply(HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"Stop","cwd":"/demo/api-server"}"#.utf8))!, now: .distantPast)
        sleepy.dismissDone()
        sleepy.toggleOpen() // peek open so the mascot is visible
        sleepy.sweep(now: Date().addingTimeInterval(400))
        let view = VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) { // all 4 v1 states, side by side
                ForEach(ChippyState.allCases, id: \.self) { s in
                    VStack {
                        ChipmunkView(state: s).frame(width: 300, height: 200)
                        Text(s.title).font(.caption).foregroundStyle(.white)
                    }
                    .background(Color(white: 0.12))
                }
            }
            HStack(alignment: .top, spacing: 12) { // idle-sleep pose (#54): static, and in the notch after a quiet 5 min
                VStack {
                    ChipmunkView(state: .idle, sleeping: true).frame(width: 300, height: 200)
                    Text("Asleep (static)").font(.caption).foregroundStyle(.white)
                }.background(Color(white: 0.12))
                let m = NotchMetrics.sample14
                VStack(spacing: 4) {
                    NotchView(model: sleepy, box: box(m)).frame(width: m.size(for: .expanded).width, height: 120)
                    Text("Asleep in the notch (quiet session peeked open, quiet 5 min)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(Density.allCases, id: \.self) { d in
                let m = NotchMetrics.sample14
                HStack(alignment: .top, spacing: 12) {
                    ForEach(ChippyState.allCases, id: \.self) { s in
                        VStack(spacing: 4) {
                            let cell = NotchModel(state: s, density: d)
                            let cs = m.size(for: d, resting: cell.resting)
                            NotchView(model: cell, box: box(m))
                                .frame(width: cs.width, height: cs.height)
                            Text("\(s.title) / \(d.title)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.25))
        let devices: [(String, NotchMetrics)] = [("14\" notch", NotchMetrics(width: 185, height: 32)),
                                                 ("16\" notch", NotchMetrics(width: 200, height: 38)),
                                                 ("no notch", .none)]
        let long = #"{"session_id":"s","hook_event_name":"PreToolUse","cwd":"/x/chippy","tool_name":"Bash","tool_input":{"command":"sleep 15; cat /tmp/chippy-trial.out | head -5; ls -la /tmp"}}"#
        let badged = devices.filter { $0.1.hasNotch }.map { ($0.0, $0.1, seededModel(count: 3, density: .collapsed, cwd: "/x/chippy")) }
        // Folded needs-you badge (#86): an approval opened, 16s passed with no hover, so it folded. 5s of the 20s are left (ring).
        let folded: [(String, NotchMetrics, NotchModel)] = devices.filter { $0.1.hasNotch }.map { name, m in
            final class Tick { var t: TimeInterval = 0 }
            let tick = Tick()
            let fm = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: tempLog()), clock: { tick.t })
            fm.receiveApproval(HookPayload(json: Data(long.replacingOccurrences(of: "PreToolUse", with: "PermissionRequest").replacingOccurrences(of: #""session_id":"s""#, with: #""session_id":"s","chippy_wait":20"#).utf8))!, Connection.detached(),
                               now: Date().addingTimeInterval(-15))
            tick.t = 16; fm.sweep()
            return (name, m, fm)
        }
        let variants = VStack(alignment: .leading, spacing: 10) {
            ForEach(devices, id: \.0) { name, m in
                HStack(alignment: .top, spacing: 12) {
                    ForEach([Density.collapsed, .compact], id: \.self) { d in
                        let model = NotchModel(state: .working, density: d)
                        let _ = { model.apply(HookPayload(json: Data(long.utf8))!); model.density = d }()
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack(alignment: .top) {
                                NotchView(model: model, box: box(m))
                                    .frame(width: m.size(for: d, resting: model.resting).width, height: m.size(for: d, resting: model.resting).height)
                                if m.hasNotch { // the camera, drawn over the content to prove nothing hides under it
                                    RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.55))
                                        .frame(width: m.width, height: m.height)
                                }
                            }
                            .frame(width: m.size(for: .compact).width, alignment: .top)
                            Text("\(name) / \(d.title)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // After a peek ends with finished items waiting: the collapsed notch carries a count badge.
            HStack(alignment: .top, spacing: 12) {
                ForEach(badged, id: \.0) { name, m, model in
                    VStack(alignment: .leading, spacing: 4) {
                        NotchView(model: model, box: box(m)).frame(width: m.size(for: .collapsed).width, height: m.size(for: .collapsed).height)
                        Text("\(name) / Collapsed + badge (3)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) { // folded approval: orange pulsing badge with a draining ring
                ForEach(folded, id: \.0) { name, m, model in
                    VStack(alignment: .leading, spacing: 4) {
                        NotchView(model: model, box: box(m)).frame(width: m.size(for: .collapsed).width, height: m.size(for: .collapsed).height)
                        Text("\(name) / Folded needs-you badge (folded=\(String(model.folded)), pending=\(model.pending.count))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(16).background(Color(white: 0.25))
        let all = VStack(spacing: 0) { view; variants }
        let r = ImageRenderer(content: all)
        writePNG(r, to: path)
    }

    /// `Chippy --render-done-detail out.png`: the opened finished-thread card with a long reply.
    @MainActor
    static func renderDoneDetail(to path: String) {
        let model = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("gal.jsonl")))
        let reply = "Fixed the login timeout: the session cookie was expiring at 5 minutes instead of 30.\n\nWhat changed:\n- **auth.ts**: session TTL 5 min → 30 min\n- **auth.test.ts**: new expiry test\n- **config.ts**: TTL read from SESSION_TTL_MINUTES\n\nNot touched: refresh-token lifetime (7 days), remember-me cookie, admin console session.\n\nRisk: users already logged in keep the old 5-minute expiry until they next sign in.\n\nShould I also bump the refresh-token lifetime, or leave it at 7 days?"
        func p(_ ev: String, _ extra: String = "") -> HookPayload { HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"\#(ev)","cwd":"/demo/api-server","chippy_branch":"fix/login-timeout"\#(extra)}"#.utf8))! }
        let noisy = CommandLine.arguments.contains("--noisy-prompt") // sample text only
        let prompt = noisy ? "<task-notification><task-id>b7x2</task-id><summary>Background command finished</summary></task-notification> Fix the login timeout bug" : "Fix the login timeout bug"
        let promptJSON = (try? JSONEncoder().encode(prompt)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\"" // escaped
        model.apply(p("UserPromptSubmit", ",\"prompt\":\(promptJSON)"))
        model.apply(p("Stop", ",\"last_assistant_message\":\"\(reply.replacingOccurrences(of: "\n", with: "\\n"))\""))
        model.toggleOpen()
        let m = NotchMetrics(width: 185, height: 32)
        let sz = m.size(for: .expanded, tall: model.tall)
        writeNotchPNG(model, m, size: sz, to: path, note: "tall=\(model.tall)")
    }

    /// #96: a finished card open while another session still works. The header must say Done, not Working.
    @MainActor
    static func renderMixedHeader(to path: String) {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let model = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: log))
        func p(_ sid: String, _ ev: String, _ extra: String = "") -> HookPayload { HookPayload(json: Data(#"{"session_id":"\#(sid)","hook_event_name":"\#(ev)","cwd":"/demo/api-server","chippy_branch":"main"\#(extra)}"#.utf8))! }
        model.apply(p("a", "UserPromptSubmit", #","prompt":"Fix the login timeout""#))
        model.apply(p("a", "Stop", #","last_assistant_message":"Fixed: the session TTL is now 30 minutes.""#))
        model.apply(p("b", "UserPromptSubmit", #","prompt":"Write the migration""#))
        model.toggleOpen()
        let m = NotchMetrics.sample14
        let sz = m.size(for: .expanded, tall: model.tall)
        writeNotchPNG(model, m, size: sz, to: path, note: "state=\(model.state) header=\(model.headerTitle)")
    }

    /// Render one notch view at `size` to a 2x PNG and print the note.
    @MainActor
    private static func writeNotchPNG(_ model: NotchModel, _ m: NotchMetrics, size sz: CGSize, to path: String, note: String) {
        let r = ImageRenderer(content: NotchView(model: model, box: box(m)).frame(width: sz.width, height: sz.height).background(Color(white: 0.25)))
        writePNG(r, to: path, note: note)
    }

    /// The one place a gallery PNG is written (2x). Any failure (render, encode, write) prints to stderr and exits 1,
    /// and "wrote ..." is only printed once the file is on disk.
    @MainActor
    private static func writePNG<V: View>(_ r: ImageRenderer<V>, to path: String, note: String = "") {
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed: \(path)\n".utf8)); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch {
            FileHandle.standardError.write(Data("could not write \(path): \(error.localizedDescription)\n".utf8)); exit(1)
        }
        print("wrote \(path)" + (note.isEmpty ? "" : " \(note)"))
    }

    private static func tempLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chippy-gallery-\(UUID().uuidString).jsonl")
    }

    /// A model with one prompt submitted and one pending approval, from sample text only. Throwaway log path per call.
    @MainActor
    private static func demoModel(prompt: String, tool: String, input: [String: Any], extra: [String: Any] = [:], log: URL) -> NotchModel {
        let model = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: log))
        let base: [String: Any] = ["session_id": "demo-a", "cwd": "/demo/api-server", "chippy_branch": "fix/login-timeout"]
        func payload(_ fields: [String: Any]) -> HookPayload? {
            (try? JSONSerialization.data(withJSONObject: base.merging(fields) { $1 })).flatMap { HookPayload(json: $0) }
        }
        guard let ask = payload(["hook_event_name": "UserPromptSubmit", "prompt": prompt]),
              let req = payload(["hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input].merging(extra) { $1 }) else {
            FileHandle.standardError.write(Data("bad demo payload\n".utf8)); exit(1)
        }
        model.apply(ask)
        model.receiveApproval(req, Connection.detached())
        return model
    }

    /// `Chippy --render-question out.png`: a question card with prompt, lead-in and a long option description (sample text only).
    @MainActor
    static func renderQuestion(to path: String) {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let model = demoModel(prompt: "Set up the login page", tool: "AskUserQuestion", input: ["questions": [["question": "Which sign-in methods should the login page offer?", "header": "Auth", "multiSelect": true, "options": [
                ["label": "Email + password", "description": "Classic form, simplest to ship. We would store salted hashes and need a reset flow, rate limiting and a lockout policy before launch."],
                ["label": "Magic link", "description": "No passwords to store"],
                ["label": "SSO", "description": "Use the school's identity provider"]]]]],
            extra: ["chippy_lead_in": "Before I wire up the login page I need to pick how people sign in. The school has an identity provider, but it is not set up for this app yet, and a plain password form would mean storing credentials."], log: log)
        let m = NotchMetrics(width: 185, height: 32)
        let sz = m.size(for: .expanded, tall: model.tall)
        let qbox = box(m); qbox.contentHeight = 540 // the app measures this; a static render must be told
        let r = ImageRenderer(content: NotchView(model: model, box: qbox).frame(width: sz.width, height: 560).background(Color(white: 0.25)))
        writePNG(r, to: path)
    }
    /// `Chippy --render-terminal-chip out.png`: the compact `repo · asked in terminal` chip and its opened card (sample text only).
    @MainActor
    static func renderTerminalChip(to path: String) {
        func make(open: Bool) -> NotchModel {
            let model = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("gal.jsonl")))
            let json: [String: Any] = ["session_id": "a", "hook_event_name": "PermissionRequest", "cwd": "/demo/api-server", "chippy_branch": "main",
                "tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "SECRET QUESTION TEXT", "header": "x", "multiSelect": true, "options": [["label": "A, x", "description": "a"], ["label": "B", "description": "b"]]]]]]
            model.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: json))!, Connection.detached())
            if open { model.toggleOpen() }
            return model
        }
        let m = NotchMetrics(width: 185, height: 32)
        func cell(_ open: Bool, _ title: String) -> some View {
            let model = make(open: open)
            let sz = m.size(for: model.density, tall: model.tall)
            return VStack(spacing: 4) {
                NotchView(model: model, box: box(m)).frame(width: sz.width, height: sz.height)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        // Worst case: done chips (long replies) mixed with two terminal chips, at the tallest the panel ever gets.
        func mixed() -> some View {
            let model = make(open: false)
            let reply = "Fixed the login timeout.\n\n" + (1...12).map { "- change \($0) in auth.ts" }.joined(separator: "\n") + "\n\nShould I also bump the refresh-token lifetime?"
            func send(_ fields: [String: Any]) {
                model.apply(HookPayload(json: try! JSONSerialization.data(withJSONObject: fields))!)
            }
            for sid in ["d1", "d2", "d3"] {
                let base: [String: Any] = ["session_id": sid, "cwd": "/demo/repo-\(sid)"]
                send(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "Fix it"]) { $1 })
                send(base.merging(["hook_event_name": "Stop", "last_assistant_message": reply]) { $1 }) // JSONSerialization does the escaping
            }
            // Two terminal chips, built explicitly: the one from make() ("a" / api-server) plus a second session.
            let ask: [String: Any] = ["session_id": "b", "hook_event_name": "PermissionRequest", "cwd": "/demo/web-app", "tool_name": "AskUserQuestion",
                "tool_input": ["questions": [["question": "q"]]]] // no options: not answerable, so it goes to the terminal
            model.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: ask))!, Connection.detached())
            precondition(model.terminalItems.count == 2, "mixed() needs exactly two terminal chips")
            model.toggleOpen()
            let b = box(m); b.contentHeight = NotchMetrics.maxExpandedHeight
            let sz = m.size(for: .expanded, tall: model.tall, contentHeight: b.contentHeight)
            return VStack(spacing: 4) {
                NotchView(model: model, box: b).frame(width: sz.width, height: sz.height)
                Text("done x3 + terminal x2, opened, at max height tall=\(model.tall)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        let r = ImageRenderer(content: HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) { cell(false, "compact"); cell(true, "opened") }
            mixed()
        }.padding(16).background(Color(white: 0.25)))
        writePNG(r, to: path)
    }
    /// `Chippy --render-waiting out.png`: the waiting list (#53) with an approval, a question and three done chips
    /// (sample repos only; note the rows never show the command or question), second row highlighted; plus the
    /// collapsed badge it opens from.
    @MainActor
    static func renderWaiting(to path: String) {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log) }
        func conn() -> Connection { Connection.detached() }
        let now = Date()
        let model = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: log))
        for (i, repo) in ["docs-site", "billing-api", "mobile-app"].enumerated() {
            model.apply(HookPayload(json: Data(#"{"session_id":"d\#(i)","hook_event_name":"Stop","cwd":"/demo/\#(repo)"}"#.utf8))!, now: now.addingTimeInterval(Double(i - 3) * 240))
        }
        model.receiveApproval(HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"PermissionRequest","cwd":"/demo/api-server","tool_name":"Bash","tool_input":{"command":"rm -rf build && npm publish"}}"#.utf8))!, conn())
        let q: [String: Any] = ["session_id": "q", "cwd": "/demo/login-page", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which auth method?", "header": "Auth", "multiSelect": false, "options": [["label": "SSO", "description": ""], ["label": "Magic link", "description": ""]]]]]]
        if let data = try? JSONSerialization.data(withJSONObject: q), let payload = HookPayload(json: data) { model.receiveApproval(payload, conn()) }
        model.openList()
        model.moveSelection(1)
        let m = NotchMetrics.sample14
        let sz = m.size(for: .expanded)
        let b = box(m)
        let badge = seededModel(count: 3, density: .collapsed, cwd: "/demo/docs-site")
        let all = HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                NotchView(model: model, box: b).frame(width: sz.width, height: 330)
                Text("Waiting list: approval, question, 3 done (2nd row selected)").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                NotchView(model: badge, box: box(m)).frame(width: m.size(for: .collapsed).width, height: m.size(for: .collapsed).height)
                Text("Collapsed + badge: tap opens the list").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(16).background(Color(white: 0.25))
        let r = ImageRenderer(content: all)
        writePNG(r, to: path)
    }

    /// `Chippy --render-resting out.png` (#85): the resting tab on three screens (awake, asleep) and the panel a click opens
    /// (Recent list with the gear, then the empty case). Sample repo names only.
    @MainActor
    static func renderResting(to path: String) {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log) }
        func fresh() -> NotchModel { NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: log)) }
        func recentModel() -> NotchModel {
            let now = Date()
            let m = fresh()
            for (i, repo) in ["docs-site", "billing-api", "mobile-app", "login-page", "api-server", "old-one"].enumerated() {
                m.apply(HookPayload(json: Data(#"{"session_id":"r\#(i)","hook_event_name":"Stop","cwd":"/demo/\#(repo)","last_assistant_message":"REPLY-TEXT-MUST-NOT-SHOW"}"#.utf8))!, now: now.addingTimeInterval(Double(i - 7) * 240))
                m.dismissDone("r\(i)")
            }
            m.toggleOpen()
            return m
        }
        let devices: [(String, NotchMetrics)] = [("14\" notch", .sample14), ("16\" notch", NotchMetrics(width: 200, height: 38)), ("no notch", .none)]
        let tabs = HStack(alignment: .top, spacing: 16) {
            ForEach(devices, id: \.0) { name, m in
                ForEach([false, true], id: \.self) { asleep in
                    let model = fresh()
                    let _ = { if asleep { model.sweep(now: Date().addingTimeInterval(400)) } }()
                    VStack(alignment: .leading, spacing: 4) {
                        ZStack(alignment: .top) {
                            Color(white: 0.8).frame(width: 240, height: 80) // stand-in for the menu bar / a window
                            NotchView(model: model, box: box(m)).frame(width: 240, height: 80)
                        }.frame(width: 240, height: 80, alignment: .top).clipped()
                        Text("\(name) · resting \(asleep ? "asleep" : "awake")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        let m = NotchMetrics.sample14
        let sz = m.size(for: .expanded)
        let panels = HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                NotchView(model: recentModel(), box: box(m)).frame(width: sz.width, height: 430)
                Text("Click: Recent (5 max, repo + age + Open) and the gear").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                let empty = fresh()
                let _ = empty.toggleOpen()
                NotchView(model: empty, box: box(m)).frame(width: sz.width, height: 180)
                Text("Click with nothing recent").font(.caption2).foregroundStyle(.secondary)
            }
        }
        let all = VStack(alignment: .leading, spacing: 16) { tabs; panels }.padding(16).background(Color(white: 0.25))
        let r = ImageRenderer(content: all)
        writePNG(r, to: path)
    }

    /// `Chippy --render-approval out.png`: approval cards for a short Bash command with a description, an Edit, and a very long command (sample text only).
    @MainActor
    static func renderApproval(to path: String) {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log) }
        func card(_ tool: String, _ input: [String: Any], height: CGFloat? = nil, prompt: String = "Fix the login timeout bug") -> some View {
            let model = demoModel(prompt: prompt, tool: tool, input: input, log: log)
            let m = NotchMetrics(width: 185, height: 32)
            let b = box(m)
            if let height { b.contentHeight = height } // the app hugs measured content; give the worst case its cap so nothing is squeezed
            let sz = m.size(for: .expanded, tall: model.tall, contentHeight: b.contentHeight)
            return NotchView(model: model, box: b).frame(width: sz.width, height: sz.height)
        }
        let long = (1...40).map { "echo step-\($0) && sleep 1" }.joined(separator: " && ") + " | sh"
        let desc100 = "Run the unit tests for the login module and then report which ones failed so we can decide what to fix"
        let longPrompt = "Fix the login timeout bug and also check that the refresh token lifetime is still correct after the change"
        let all = HStack(alignment: .top, spacing: 12) {
            card("Bash", ["command": "npm install", "description": "Install project dependencies"])
            card("Edit", ["file_path": "/demo/api-server/Sources/Auth.swift", "old_string": "a", "new_string": "b"])
            // worst case at the tallest the real card ever gets (the app hugs content up to this cap)
            card("Bash", ["command": long, "description": desc100], height: NotchMetrics.maxExpandedHeight, prompt: longPrompt)
        }.padding(12).background(Color(white: 0.25))
        let r = ImageRenderer(content: all)
        writePNG(r, to: path)
    }

    /// `Chippy --render-tab out.png`: no room beside the camera (menu extras hug the notch), so the indicator is a tab below it.
    /// A mock menu bar with items touching both edges and the camera in red; wings (room) vs tab (no room), per density.
    @MainActor
    static func renderTab(to path: String) {
        func row(_ title: String, _ left: CGFloat, _ right: CGFloat, _ d: Density, waiting n: Int = 1) -> some View {
            var m = NotchMetrics.sample14; m.leftGap = left; m.rightGap = right
            let model = seededModel(count: n, density: d)
            let w = NotchMetrics.sample14.size(for: .compact).width
            return VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .top) {
                    Color(white: 0.55).frame(width: w, height: 80) // desktop
                    Color(white: 0.85).frame(width: w, height: m.band) // menu bar
                        .frame(maxHeight: .infinity, alignment: .top)
                    HStack(spacing: 0) { // items hugging the camera's edges
                        RoundedRectangle(cornerRadius: 3).fill(.blue).frame(width: 60, height: 16)
                        Spacer().frame(width: m.width + 2 * 4)
                        RoundedRectangle(cornerRadius: 3).fill(.purple).frame(width: 60, height: 16)
                    }.frame(maxHeight: .infinity, alignment: .top).padding(.top, 8)
                    NotchView(model: model, box: box(m)).frame(width: w, height: 80, alignment: .top)
                    RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.5)).frame(width: m.width, height: m.height)
                        .frame(maxHeight: .infinity, alignment: .top)
                }.frame(width: w, height: 80)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        let all = VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                row("room: wings / collapsed", .infinity, .infinity, .collapsed)
                row("room: wings / compact", .infinity, .infinity, .compact)
            }
            HStack(spacing: 12) {
                row("no room: tab / collapsed", 4, 4, .collapsed)
                row("no room: tab / compact", 4, 4, .compact)
            }
            HStack(spacing: 12) { // after a peek ends: collapsed with the count of waiting items
                row("wings / collapsed + badge (1)", .infinity, .infinity, .collapsed, waiting: 1)
                row("wings / collapsed + badge (12 -> 9+)", .infinity, .infinity, .collapsed, waiting: 12)
            }
            HStack(spacing: 12) {
                row("tab / collapsed + badge (3)", 4, 4, .collapsed, waiting: 3)
                row("tab / collapsed + badge (12 -> 9+)", 4, 4, .collapsed, waiting: 12)
            }
        }.padding(16).background(Color(white: 0.25))
        let r = ImageRenderer(content: all)
        writePNG(r, to: path)
    }

    // MARK: #101 NEEDS YOU / FINISHED

    /// A model with the waiting list open: `needs` rows (approval, question, terminal ask in turn) and `finished` chips.
    /// `names` are cwd folder names under /work; the injected cache turns the worktree-style ones into repo + worktree.
    @MainActor
    private static func listModel(needs: Int, finished: Int, names: [String]? = nil, kinds: [String]? = nil, asksYou: Bool = false) -> NotchModel {
        let cache = RepoIdentityCache(resolver: { cwd in
            let n = (cwd as NSString).lastPathComponent
            switch n {
            case "fix-53", "fix-51": return RepoLabel(repo: "govapps", worktree: n)
            case "verify-58b", "verify-59": return RepoLabel(repo: "factory", worktree: n)
            default: return RepoLabel(repo: n)
            }
        }, background: { $0() }, deliver: { $0() })
        let model = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: tempLog()), identities: cache)
        let pool = ["govapps", "factory", "api-server", "docs-site", "billing-api", "login-page", "mobile-app", "web-app", "data-lab", "kiosk", "portal", "ledger"]
        let host = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" } // any running app, so Jump shows
        var hostFields: [String: Any] = [:]
        if let host, let b = host.bundleIdentifier { hostFields = ["chippy_host_pid": Int(host.processIdentifier), "chippy_host_bundle": b] }
        let now = Date()
        for i in 0..<finished {
            let name = names.map { $0[(needs + i) % $0.count] } ?? pool[(needs + i + 3) % pool.count]
            let reply = asksYou && i == 0 ? "Done.\n\nShould I also bump the version?" : "Done."
            model.apply(HookPayload(json: try! JSONSerialization.data(withJSONObject: ["session_id": "f\(i)", "hook_event_name": "Stop", "cwd": "/work/\(name)", "last_assistant_message": reply]))!,
                        now: now.addingTimeInterval(Double(i - finished) * 300 - 60))
        }
        for i in 0..<needs {
            let name = names.map { $0[i % $0.count] } ?? pool[i % pool.count]
            let kind = kinds.map { $0[i % $0.count] } ?? ["approval", "question", "terminal", "approval", "terminal"][i % 5]
            var o: [String: Any] = ["session_id": "n\(i)", "hook_event_name": "PermissionRequest", "cwd": "/work/\(name)", "chippy_wait": 120]
            o.merge(hostFields) { $1 }
            switch kind {
            case "approval": o["tool_name"] = "Bash"; o["tool_input"] = ["command": "npm publish"]
            case "question":
                o["tool_name"] = "AskUserQuestion"
                o["tool_input"] = ["questions": [["question": "Which one?", "header": "H", "multiSelect": false, "options": [["label": "a", "description": ""], ["label": "b", "description": ""]]],
                                                 ["question": "And then?", "header": "H2", "multiSelect": false, "options": [["label": "c", "description": ""], ["label": "d", "description": ""]]]]]
            default: o["tool_name"] = "AskUserQuestion"; o["tool_input"] = ["questions": [["question": "q"]]] // no options: lands in the terminal
            }
            model.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: o))!, Connection.detached())
        }
        model.openList()
        return model
    }

    /// Estimated card height for a static render (the app measures it): fixed chrome plus the two sections the layout chose.
    @MainActor
    private static func listHeight(_ model: NotchModel) -> CGFloat {
        let l = model.waitingLayout
        let needs = l.needs.isEmpty ? 0 : WaitingList.sectionHeaderHeight + l.needsHeight
        let fin = l.totalFinished == 0 ? 0 : WaitingList.sectionHeaderHeight + CGFloat(l.finished.count) * WaitingList.finishedRowHeight + (l.hiddenFinished > 0 ? WaitingList.moreRowHeight : 0)
        let gap = (needs > 0 && fin > 0) ? WaitingList.sectionGap : 0
        return min(WaitingList.chrome + needs + gap + fin + 10, NotchMetrics.maxExpandedHeight)
    }

    @MainActor
    private static func listCell(_ model: NotchModel, _ title: String) -> some View {
        let m = NotchMetrics.sample14
        let b = box(m)
        let h = listHeight(model)
        b.contentHeight = h - 10
        let w = m.size(for: .expanded).width
        return VStack(alignment: .leading, spacing: 4) {
            NotchView(model: model, box: b).frame(width: w, height: m.size(for: .expanded, contentHeight: b.contentHeight).height, alignment: .top)
            Text("\(title) (card \(Int(h))pt of \(Int(NotchMetrics.maxExpandedHeight)))").font(.caption2).foregroundStyle(.secondary)
        }.frame(width: w, alignment: .leading)
    }

    /// `Chippy --render-needs-finished out.png` (#101): 0/1/5 needs-you x 0/3/6 finished, the six-row screenshot case with
    /// consistent repo + worktree labels, and the height cap (needs-you never cut; finished shrinks first, then needs-you scrolls).
    @MainActor
    static func renderNeedsFinished(to path: String) {
        let grid = VStack(alignment: .leading, spacing: 16) {
            ForEach([0, 1, 5], id: \.self) { n in
                HStack(alignment: .top, spacing: 16) {
                    ForEach([0, 3, 6], id: \.self) { f in
                        if n == 0 && f == 0 {
                            Text("0 needs you x 0 finished: nothing to list, the notch rests").font(.caption2).foregroundStyle(.secondary).frame(width: 380, height: 60)
                        } else {
                            listCell(listModel(needs: n, finished: f, asksYou: f == 3 && n == 1), "\(n) needs you x \(f) finished")
                        }
                    }
                }
            }
        }
        let six = listCell(listModel(needs: 3, finished: 3, names: ["govapps", "fix-53", "fix-51", "factory", "verify-58b", "verify-59"], kinds: ["approval", "question", "terminal"]),
                           "six rows: govapps, fix-53, fix-51, factory, verify-58b, verify-59")
        let caps = HStack(alignment: .top, spacing: 16) {
            listCell(listModel(needs: 6, finished: 6), "cap: 6 needs x 6 finished, finished shrinks to 1")
            listCell(listModel(needs: 9, finished: 6), "cap: 9 needs x 6 finished, needs-you scrolls")
        }
        let all = VStack(alignment: .leading, spacing: 20) { grid; HStack(alignment: .top, spacing: 16) { six; caps } }.padding(16).background(Color(white: 0.25))
        let r = ImageRenderer(content: all)
        writePNG(r, to: path)
    }

    /// `Chippy --render-badge-dot out.png` (#101): the collapsed notch with only finished items waiting (a dot).
    @MainActor
    static func renderBadgeDot(to path: String) {
        let m = NotchMetrics.sample14
        let dot = seededModel(count: 3, density: .collapsed, cwd: "/work/govapps")
        let all = HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                NotchView(model: dot, box: box(m)).frame(width: m.size(for: .collapsed).width, height: m.size(for: .collapsed).height)
                Text("3 finished, nothing needs you: dot (badge=\(dot.badge ?? "nil") dot=\(String(dot.badgeDot)))").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(16).background(Color(white: 0.25))
        let r = ImageRenderer(content: all)
        writePNG(r, to: path)
    }
}
