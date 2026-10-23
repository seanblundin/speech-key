import AppKit
import SwiftUI

/// Renders every pill state to PNGs over light and dark backgrounds, for design review
/// without needing screen-recording permission: `Utter --render-pill <dir>`.
@MainActor
enum PillRenderer {
    static func renderAll(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let modes: [(String, PillModel.Mode)] = [
            ("1-listening", .listening), ("2-handsfree", .handsFree), ("2b-handsfree-finishing", .finishing(42)), ("3-working", .working),
            ("4-done-fixed", .done("Fixed NOVA, Tighe")), ("5-done", .done("Pasted")), ("6-message", .message("Didn't catch that")),
            ("9-utter-listening", .listening), ("9-utter-handsfree", .handsFree), ("9-utter-thinking", .working),
            ("9-utter-done", .done("Added Neve → Niamh")),
        ]
        let voice: [CGFloat] = [0.05, 0.12, 0.30, 0.55, 0.72, 0.95, 0.70, 0.50, 0.33, 0.15, 0.06]
        for (name, mode) in modes {
            // "clear": no backdrop, for laying the pill over other images (App Store screenshots).
            for (bgName, bg) in [("light", Color(white: 0.96)), ("dark", Color(red: 0.12, green: 0.13, blue: 0.16)), ("clear", Color.clear)] {
                let model = PillModel()
                model.mode = mode
                model.levels = voice
                model.startedAt = Date().addingTimeInterval(-42)
                model.talkingToUtter = name.hasPrefix("9-")
                let view = ZStack {
                    bg
                    PillView(model: model)
                }
                .frame(width: 360, height: 64)
                .environment(\.colorScheme, bgName == "light" ? .light : .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(bgName).png"))
            }
        }
        // The two windows, with sample content.
        let setupModel = SetupModel()
        setupModel.mic = true; setupModel.micAsked = true; setupModel.keys = false; setupModel.paste = false; setupModel.globe = false
        setupModel.engine = .ready
        write(SetupView(model: setupModel, onDone: {}).background(Color(nsColor: .windowBackgroundColor)), to: "\(dir)/7-setup.png")

        print("rendered pill states to \(dir)")
    }

    /// Draws a real (AppKit-backed) view hierarchy offscreen, so buttons and fields render too.
    static func write<V: View>(_ view: V, to path: String, appearance: NSAppearance.Name = .aqua) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
