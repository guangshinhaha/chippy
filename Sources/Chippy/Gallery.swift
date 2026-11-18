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
        let badged = devices.filter { $0.1.hasNotch }.map { ($0.0, $0.1, seededModel(count: 3, density: .collapsed, cwd: "/x/chippy")) }
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
            // After a peek ends with finished items waiting: the collapsed notch carries a count badge.
            HStack(alignment: .top, spacing: 12) {
                ForEach(badged, id: \.0) { name, m, model in
                    VStack(alignment: .leading, spacing: 4) {
                        NotchView(model: model, box: box(m)).frame(width: m.size(for: .collapsed).width, height: m.size(for: .collapsed).height)
                        Text("\(name) / Collapsed + badge (3)").font(.caption2).foregroundStyle(.secondary)
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
    /// `Chippy --render-waiting out.png`: the waiting list (#53) with an approval, a question and three done chips
    /// (sample repos only; note the rows never show the command or question), second row highlighted; plus the
    /// collapsed badge it opens from.
    @MainActor
    static func renderWaiting(to path: String) {
        func fresh() -> NotchModel { NotchModel(always: AlwaysStore(url: nil), log: EventLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("gal.jsonl"))) }
        func conn() -> Connection { Connection.detached() }
        let now = Date()
        let model = fresh()
        for (i, repo) in ["docs-site", "billing-api", "mobile-app"].enumerated() {
            model.apply(HookPayload(json: Data(#"{"session_id":"d\#(i)","hook_event_name":"Stop","cwd":"/demo/\#(repo)"}"#.utf8))!, now: now.addingTimeInterval(Double(i - 3) * 240))
        }
        model.receiveApproval(HookPayload(json: Data(#"{"session_id":"a","hook_event_name":"PermissionRequest","cwd":"/demo/api-server","tool_name":"Bash","tool_input":{"command":"rm -rf build && npm publish"}}"#.utf8))!, conn())
        let q: [String: Any] = ["session_id": "q", "cwd": "/demo/login-page", "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Which auth method?", "header": "Auth", "multiSelect": false, "options": [["label": "SSO", "description": ""], ["label": "Magic link", "description": ""]]]]]]
        model.receiveApproval(HookPayload(json: try! JSONSerialization.data(withJSONObject: q))!, conn())
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
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path) height=\(b.contentHeight)")
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
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
    }
}
