import AppKit
import ChippyCore
import SwiftUI

/// `Chippy --render-gallery out.png` renders every state x density to a PNG, headless.
/// Used as evidence for the state/density acceptance checks.
enum Gallery {
    @MainActor
    static func render(to path: String) {
        let view = VStack(alignment: .leading, spacing: 12) {
            ForEach(Density.allCases, id: \.self) { d in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(ChippyState.allCases, id: \.self) { s in
                        VStack(spacing: 4) {
                            NotchView(model: NotchModel(state: s, density: d))
                                .frame(width: 300, height: NotchPanel.size(for: d, notchWidth: 160).height)
                            Text("\(s.title) / \(d.title)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.25))
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8)); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { print(error); exit(1) }
        print("wrote \(path)")
    }
}
