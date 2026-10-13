import AppKit
import MiradaKit
import SwiftUI

/// `Mirada --render-screenshots <dir> --still-before <png> --still-after <png>`
/// renders the real views offscreen, light and dark, with still images in
/// place of the camera, then quits. Used for the README.
enum Screenshots {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-screenshots"), i + 1 < args.count else { return }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let dir = URL(fileURLWithPath: args[i + 1])
        guard let before = value("--still-before").flatMap(NSImage.init(contentsOfFile:)),
              let after = value("--still-after").flatMap(NSImage.init(contentsOfFile:)) else {
            FileHandle.standardError.write(Data("need --still-before and --still-after\n".utf8))
            exit(64)
        }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let suffix = dark ? "dark" : "light"

                let live = demoModel(before: before, after: after)
                render(ContentView().environment(live), dark: dark, to: dir.appendingPathComponent("live-\(suffix).png"))

                let file = demoModel(before: before, after: after)
                file.mode = .file
                file.stopLive()
                file.fileState = .running(URL(fileURLWithPath: "/Users/you/Movies/standup-call.mov"),
                                          FileJobProgress(fraction: 0.62, frames: 1120, fps: 96, eta: 7))
                render(ContentView().environment(file), dark: dark, to: dir.appendingPathComponent("file-\(suffix).png"))

                let cal = demoModel(before: before, after: after)
                render(CalibrationView(scrolls: false).environment(cal), dark: dark, to: dir.appendingPathComponent("calibrate-\(suffix).png"), height: nil)
            }
            exit(0)
        }
    }

    @MainActor
    static func demoModel(before: NSImage, after: NSImage) -> AppModel {
        let m = AppModel()
        m.still = AppModel.Still(before: before, after: after)
        m.cameraState = .running("FaceTime HD Camera")
        m.face = .tracking
        m.fade = 1
        m.split = 0.5
        m.statsLine = "vision 8.4 · model 1.4 · compose 0.9 · total 9.6 ms p50"
        m.virtualCamera = .publishing(.obs)
        m.extensions.refresh()
        return m
    }

    @MainActor
    static func render(_ view: some View, dark: Bool, to url: URL, height: CGFloat? = nil) {
        let content = view
            .frame(width: WindowShape.width, height: height)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
