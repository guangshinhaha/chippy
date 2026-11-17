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
}
