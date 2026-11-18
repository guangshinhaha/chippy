import AppKit
import ChippyCore
import SwiftUI

/// `Chippy --render-gallery out.png` renders every state x density to a PNG, headless.
/// Used as evidence for the state/density acceptance checks.
enum Gallery {
    @MainActor private static func box(_ m: NotchMetrics) -> MetricsBox { let b = MetricsBox(); b.metrics = m; return b }

    @MainActor
    static func render(to path: String) {
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
            ForEach(Density.allCases, id: \.self) { d in
                let m = NotchMetrics.sample14
                HStack(alignment: .top, spacing: 12) {
                    ForEach(ChippyState.allCases, id: \.self) { s in
                        VStack(spacing: 4) {
                            NotchView(model: NotchModel(state: s, density: d), box: box(m))
                                .frame(width: m.size(for: d).width, height: m.size(for: d).height)
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
        let variants = VStack(alignment: .leading, spacing: 10) {
            ForEach(devices, id: \.0) { name, m in
                HStack(alignment: .top, spacing: 12) {
                    ForEach([Density.collapsed, .compact], id: \.self) { d in
                        let model = NotchModel(state: .working, density: d)
                        let _ = { model.apply(HookPayload(json: Data(long.utf8))!); model.density = d }()
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack(alignment: .top) {
                                NotchView(model: model, box: box(m))
                                    .frame(width: m.size(for: d).width, height: m.size(for: d).height)
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
        }.padding(16).background(Color(white: 0.25))
        let all = VStack(spacing: 0) { view; variants }
        let r = ImageRenderer(content: all)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8)); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { print(error); exit(1) }
        print("wrote \(path)")
    }

    /// `Chippy --render-done-detail out.png`: the opened finished-thread card with a long reply.
    @MainActor
    static func renderDoneDetail(to path: String) {
        let model = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("gal.jsonl")))
        let reply = "Fixed the login timeout: the session cookie was expiring at 5 minutes instead of 30.\n\nWhat changed:\n- **auth.ts**: session TTL 5 min → 30 min\n- **auth.test.ts**: new expiry test\n- **config.ts**: TTL read from SESSION_TTL_MINUTES\n\nNot touched: refresh-token lifetime (7 days), remember-me cookie, admin console session.\n\nRisk: users already logged in keep the old 5-minute expiry until they next sign in.\n\nShould I also bump the refresh-token lifetime, or leave it at 7 days?"
        func p(_ ev: String, _ extra: String = "") -> HookPayload { HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"\#(ev)","cwd":"/demo/api-server","chippy_branch":"fix/login-timeout"\#(extra)}"#.utf8))! }
        model.apply(p("UserPromptSubmit", #","prompt":"Fix the login timeout bug""#))
        model.apply(p("Stop", ",\"last_assistant_message\":\"\(reply.replacingOccurrences(of: "\n", with: "\\n"))\""))
        model.toggleOpen()
        let m = NotchMetrics(width: 185, height: 32)
        let sz = m.size(for: .expanded, tall: model.tall)
        let r = ImageRenderer(content: NotchView(model: model, box: box(m)).frame(width: sz.width, height: sz.height).background(Color(white: 0.25)))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path) tall=\(model.tall)")
    }

    /// `Chippy --render-question out.png`: a question card with prompt, lead-in and a long option description (sample text only).
    @MainActor
    static func renderQuestion(to path: String) {
        let model = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("gal.jsonl")))
        model.apply(HookPayload(json: Data(#"{"session_id":"demo-a","hook_event_name":"UserPromptSubmit","cwd":"/demo/api-server","chippy_branch":"fix/login-timeout","prompt":"Set up the login page"}"#.utf8))!)
        let json: [String: Any] = ["session_id": "demo-a", "hook_event_name": "PermissionRequest", "cwd": "/demo/api-server", "chippy_branch": "fix/login-timeout",
            "tool_name": "AskUserQuestion", "chippy_lead_in": "Before I wire up the login page I need to pick how people sign in. The school has an identity provider, but it is not set up for this app yet, and a plain password form would mean storing credentials.",
            "tool_input": ["questions": [["question": "Which auth method should the login page use?", "header": "Auth", "multiSelect": false, "options": [
                ["label": "Email + password", "description": "Classic form, simplest to ship. We would store salted hashes and need a reset flow, rate limiting and a lockout policy before launch."],
                ["label": "Magic link", "description": "No passwords to store"],
                ["label": "SSO", "description": "Use the school's identity provider"]]]]]]
        model.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: json))!, Connection.detached())
        let m = NotchMetrics(width: 185, height: 32)
        let sz = m.size(for: .expanded, tall: model.tall)
        let r = ImageRenderer(content: NotchView(model: model, box: box(m)).frame(width: sz.width, height: 560).background(Color(white: 0.25)))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
    }
    /// `Chippy --render-approval out.png`: approval cards for a short Bash command with a description, an Edit, and a very long command (sample text only).
    @MainActor
    static func renderApproval(to path: String) {
        func card(_ tool: String, _ input: [String: Any], height: CGFloat? = nil, prompt: String = "Fix the login timeout bug") -> some View {
            let model = NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("gal.jsonl")))
            model.apply(HookPayload(json: Data(#"{"session_id":"demo-a","hook_event_name":"UserPromptSubmit","cwd":"/demo/api-server","chippy_branch":"fix/login-timeout","prompt":"\#(prompt)"}"#.utf8))!)
            let json: [String: Any] = ["session_id": "demo-a", "hook_event_name": "PermissionRequest", "cwd": "/demo/api-server", "chippy_branch": "fix/login-timeout", "tool_name": tool, "tool_input": input]
            model.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: json))!, Connection.detached())
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
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
    }

    /// `Chippy --render-tab out.png`: no room beside the camera (menu extras hug the notch), so the indicator is a tab below it.
    /// A mock menu bar with items touching both edges and the camera in red; wings (room) vs tab (no room), per density.
    @MainActor
    static func renderTab(to path: String) {
        func row(_ title: String, _ left: CGFloat, _ right: CGFloat, _ d: Density) -> some View {
            var m = NotchMetrics.sample14; m.leftGap = left; m.rightGap = right
            let model = NotchModel(state: .done, density: d)
            let _ = { model.apply(HookPayload(json: Data(#"{"session_id":"s","hook_event_name":"Stop","cwd":"/demo/api-server","chippy_branch":"main"}"#.utf8))!); model.density = d }()
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
        }.padding(16).background(Color(white: 0.25))
        let r = ImageRenderer(content: all)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
    }
}
