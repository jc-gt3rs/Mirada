import MiradaKit
import SwiftUI

/// A guided three-step calibration: where the camera is, how far you sit
/// (which measures the focal length), and your eye spacing.
struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var distance = 55.0
    @State private var measured: Double?
    @State private var gazeNote = "// first look at the middle, then at the camera"
    /// Off for offscreen snapshots (the renderer can't draw scroll views).
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView { content }
                .frame(width: 360, height: 600)
                .background(Theme.paper)
        } else {
            content.frame(width: 360).background(Theme.paper)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("calibrate").font(.display(26))
                Spacer()
                Button("done") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.defaultAction)
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Tag(1, "where is your camera?")
                    ScreenDiagram(offsetX: model.settings.camera.offsetX, offsetY: model.settings.camera.offsetY,
                                  screenHeightCM: DisplayInfo.builtInSizeMM().map { $0.height / 10 } ?? 30)
                        .frame(height: 74)
                    row("above screen centre", value: -model.settings.camera.offsetY, unit: "cm", range: 0...40) { model.settings.camera.offsetY = -$0 }
                    row("right of centre", value: model.settings.camera.offsetX, unit: "cm", range: -30...30) { model.settings.camera.offsetX = $0 }
                }
                .padding(12)
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Tag(2, "how far do you sit?")
                    Text(autoLine).font(.note).foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    row("distance to your eyes", value: distance, unit: "cm", range: 30...120) { distance = $0 }
                    HStack {
                        Button("measure focal length") { measured = model.measureFocalLength(distanceCM: distance) }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(!model.canMeasure)
                        if model.settings.camera.focalCalibrated {
                            Button("automatic") {
                                model.settings.camera.focalCalibrated = false
                                measured = nil
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                        Spacer()
                        Text(String(format: "f = %.0f px", measured ?? model.focalLength ?? model.settings.camera.focalLength))
                            .font(.mono).foregroundStyle(Theme.inkSoft)
                    }
                    Text(model.canMeasure ? "// optional: only if the distance above looks wrong" : "// needs your face in :live: view")
                        .font(.fine).foregroundStyle(Theme.inkFaint)
                }
                .padding(12)
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Tag(3, "your eyes")
                    row("pupil distance", value: model.settings.camera.ipd, unit: "cm", range: 5.2...7.4, step: 0.1) { model.settings.camera.ipd = $0 }
                    Text("// 6.3 cm is the adult average").font(.fine).foregroundStyle(Theme.inkFaint)
                }
                .padding(12)
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Tag(4, "follow where you look")
                        Spacer()
                        PillToggle(isOn: Binding(get: { model.settings.followGaze }, set: { model.settings.followGaze = $0 }),
                                   label: "Follow where you look")
                    }
                    Text(model.settings.followGaze
                         ? "// reads your pupils, so looking at notes or the side of the screen still lands on the camera"
                         : "// assumes you look at the middle of the screen")
                        .font(.fine).foregroundStyle(Theme.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("1. middle") {
                            model.recenterGaze()
                            gazeNote = "// middle saved. now look straight at the camera and press 2"
                        }
                        .buttonStyle(QuietButtonStyle())
                        Button("2. camera") {
                            Task {
                                if let g = await model.calibrateLookingAtCamera() {
                                    gazeNote = String(format: "// learned: vertical gain %.1f", g)
                                } else {
                                    gazeNote = "// couldn't read your eyes; face the camera with eyes open and try again"
                                }
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    .disabled(!model.settings.followGaze || !model.canMeasure)
                    Text(model.canMeasure ? gazeNote : "// needs your face in :live: view")
                        .font(.fine).foregroundStyle(Theme.inkFaint)
                }
                .padding(12)
            }

            HStack {
                Button("reset to defaults") { model.resetCalibration() }.buttonStyle(QuietButtonStyle())
                Spacer()
            }
        }
        .padding(Theme.gutter)
        .foregroundStyle(Theme.ink)
    }

    private var autoLine: String {
        let d = model.distanceCM.map { String(format: "you're about %.0f cm away", $0) } ?? "sit in view to see your distance"
        switch model.focalSource {
        case "camera": return "// automatic: your camera reports its lens. \(d)"
        case "measured": return "// using your measurement. \(d)"
        default: return "// assuming 55 cm until your camera reports its lens. \(d)"
        }
    }

    private func row(_ label: String, value: Double, unit: String, range: ClosedRange<Double>, step: Double = 0.5,
                     set: @escaping @MainActor (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.note).foregroundStyle(Theme.inkSoft)
                Spacer()
                Text(String(format: step < 0.5 ? "%.1f %@" : "%.1f %@", value, unit)).font(.mono)
            }
            GreenSlider(value: Binding(get: { value }, set: { v in MainActor.assumeIsolated { set(v) } }), range: range, step: step, label: label,
                        valueText: { String(format: "%.1f %@", $0, unit) })
        }
    }
}

/// A screen with the camera dot, so offsets are easy to picture.
struct ScreenDiagram: View {
    let offsetX: Double
    let offsetY: Double
    /// Physical height of the screen drawn, so the camera lands where it really is.
    var screenHeightCM: Double = 30

    var body: some View {
        Canvas { ctx, size in
            let screen = CGRect(x: size.width * 0.28, y: size.height * 0.32, width: size.width * 0.44, height: size.height * 0.6)
            ctx.stroke(Path(roundedRect: screen, cornerRadius: 4), with: .color(Theme.inkSoft), lineWidth: 1)
            let centre = CGPoint(x: screen.midX, y: screen.midY)
            ctx.fill(Path(ellipseIn: CGRect(x: centre.x - 2, y: centre.y - 2, width: 4, height: 4)), with: .color(Theme.inkFaint))
            let scale = screen.height / screenHeightCM
            let cam = CGPoint(x: centre.x + offsetX * scale, y: centre.y + offsetY * scale)
            var line = Path()
            line.move(to: centre)
            line.addLine(to: cam)
            ctx.stroke(line, with: .color(Theme.green), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.fill(Path(ellipseIn: CGRect(x: cam.x - 4, y: cam.y - 4, width: 8, height: 8)), with: .color(Theme.green))
        }
        .accessibilityElement()
        .accessibilityLabel(String(format: "Camera %.1f centimetres above and %.1f to the right of the screen centre", -offsetY, offsetX))
    }
}
