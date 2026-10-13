import AppKit
import MiradaKit
import SwiftUI

struct LivePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            PreviewCard()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Tag(1, "strength")
                    Spacer()
                    Text("\(Int((model.settings.strength * 100).rounded()))%").font(.mono).foregroundStyle(Theme.inkSoft)
                        .accessibilityHidden(true)
                }
                GreenSlider(value: Binding(get: { model.settings.strength }, set: { model.setStrength($0) }), label: "Gaze strength")

                HStack {
                    Tag(2, "camera")
                    Spacer()
                    MenuChip(title: cameraName, items: [("", "Default camera")] + model.cameras.map { ($0.id, $0.name) },
                             selected: model.settings.cameraID ?? "", onSelect: { model.settings.cameraID = $0.isEmpty ? nil : $0 },
                             label: "Camera")
                }

                HStack(alignment: .firstTextBaseline) {
                    Tag(3, "virtual camera")
                    Spacer()
                    PillToggle(isOn: Binding(get: { model.settings.publishVirtualCamera }, set: { model.settings.publishVirtualCamera = $0 }),
                               label: "Send to virtual camera")
                }
                VirtualCameraLine()

                HStack(alignment: .firstTextBaseline) {
                    Tag(4, "debug overlay")
                    Spacer()
                    PillToggle(isOn: Binding(get: { model.settings.debugOverlay }, set: { model.settings.debugOverlay = $0 }),
                               label: "Debug overlay")
                        .help("Draw the face box, eye points, crops and decisions into the video, everywhere it goes (⌘D)")
                }
                if model.settings.debugOverlay {
                    Text("// shown in the preview and in every app using the virtual camera, even with this window closed")
                        .font(.fine).foregroundStyle(Theme.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.toggleCorrection()
                } label: {
                    Label(model.settings.enabled ? "correction on" : "correction off", systemImage: model.settings.enabled ? "eye" : "eye.slash")
                }
                .buttonStyle(QuietButtonStyle())
                .help("Toggle correction (⌘G)")
                .accessibilityHint("Command G")
                Button {
                    model.calibrationOpen = true
                } label: {
                    Label("calibrate", systemImage: "scope")
                }
                .buttonStyle(QuietButtonStyle())
                .help("Calibration (⌘K)")
                Spacer()
            }

            if !model.statsLine.isEmpty {
                Text(model.statsLine).font(.fine).foregroundStyle(Theme.inkFaint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityLabel("Latency \(model.statsLine)")
            }
        }
    }

    private var cameraName: String {
        model.cameras.first { $0.id == model.settings.cameraID }?.name ?? "Default camera"
    }
}

struct VirtualCameraLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text(line).font(.note).foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if model.extensions.status == .notInstalled {
                Button("install") { model.extensions.install() }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var line: String {
        switch model.virtualCamera {
        case .off: return "// not sending"
        case .publishing(.mirada): return ":mirada cam: live"
        case .publishing(.obs):
            return model.extensions.status == .needsPaidTeam
                ? ":obs cam: live // pick \"OBS Virtual Camera\" in your call app"
                : ":obs cam: live"
        case .unavailable(let why): return "// \(why)"
        }
    }
}

/// The preview with before/after, status chip and empty states.
struct PreviewCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card {
            GeometryReader { proxy in
                ZStack {
                    Theme.night
                    if let still = model.still {
                        StillPreview(still: still, split: previewSplit)
                    } else {
                        // Unmirrored while debugging, so the readout reads the way call apps receive it.
                        PreviewView(after: model.after, before: model.before, split: previewSplit, mirrored: !model.settings.debugOverlay)
                    }
                    if showsEmptyState { EmptyState() }
                    if model.compare == .split, !showsEmptyState {
                        SplitHandle(split: $model.split)
                    }
                    VStack {
                        HStack {
                            if !showsEmptyState { cornerLabel(":before:", visible: model.compare == .split ? model.split > 0.12 : model.showBefore) }
                            Spacer()
                            if !showsEmptyState { cornerLabel(":after:", visible: model.compare == .split ? model.split < 0.88 : !model.showBefore) }
                        }
                        Spacer()
                        HStack(alignment: .bottom) {
                            LockChip()
                            Spacer()
                            ChipPicker(selection: $model.compare, options: [(.split, "split"), (.flip, "flip")], onBand: true, label: "Compare")
                                .background(Capsule().fill(Theme.night.opacity(0.55)))
                        }
                    }
                    .padding(10)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            // One ratio at every window width; the video fills it (aspect fill).
            .aspectRatio(Theme.previewRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera preview")
    }

    private var showsEmptyState: Bool {
        if model.still != nil { return false }
        if case .running = model.cameraState { return false }
        return true
    }

    private var previewSplit: CGFloat {
        model.compare == .split ? model.split : (model.showBefore ? 1 : 0)
    }

    private func cornerLabel(_ text: String, visible: Bool) -> some View {
        Text(text).font(.tag).tracking(0.6).foregroundStyle(Theme.onBand)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Theme.night.opacity(0.55)))
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// `// gaze locked` with the eye that opens on lock. The amber ring sweeps in
/// once; Reduce Motion swaps both for a plain crossfade.
struct LockChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let locked = model.isLocked
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(Theme.night.opacity(0.4))
                Circle()
                    .trim(from: 0, to: locked ? 1 : 0)
                    .stroke(Theme.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                MarkView(openness: locked ? 1 : 0.3, ink: locked ? Theme.amber : Theme.onBand, paper: Theme.night, medallion: false)
                    .padding(3)
            }
            .frame(width: 24, height: 24)
            Text(model.statusText).font(.tag).tracking(0.5).foregroundStyle(locked ? Theme.amber : Theme.onBand)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.opacity)
        }
        .padding(.leading, 3).padding(.trailing, 9).padding(.vertical, 3)
        .background(Capsule().fill(Theme.night.opacity(0.62)))
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.72), value: locked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.statusText.replacingOccurrences(of: "// ", with: ""))
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            MarkView(openness: openness, ink: Theme.onBand, paper: Theme.night)
                .frame(width: 92, height: 92)
            Text(message).font(.mono).foregroundStyle(Theme.onBand).multilineTextAlignment(.center)
            if case .failed = model.cameraState {
                Button("open camera settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
                .buttonStyle(QuietButtonStyle())
                .colorScheme(.dark)
            }
        }
        .padding()
    }

    private var openness: CGFloat {
        if case .failed = model.cameraState { return 0.15 }
        return 0.55
    }

    private var message: String {
        switch model.cameraState {
        case .starting: "// waking the camera"
        case .stopped: "// camera resting"
        case .failed(let why): "#1 allow camera access\n// \(why)"
        case .running: ""
        }
    }
}

struct SplitHandle: View {
    @Binding var split: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let x = proxy.size.width * split
            ZStack {
                Rectangle().fill(Theme.onBand).frame(width: 1.5)
                Circle().fill(Theme.onBand).frame(width: 18, height: 18)
                    .overlay(Image(systemName: "chevron.left.chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.night))
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
            .position(x: x, y: proxy.size.height / 2)
            .frame(height: proxy.size.height)
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    split = min(max(g.location.x / max(proxy.size.width, 1), 0), 1)
                })
        }
        .accessibilityElement()
        .accessibilityLabel("Before and after divider")
        .accessibilityValue("\(Int(split * 100)) percent original")
        .accessibilityAdjustableAction { dir in
            split = min(max(split + (dir == .increment ? 0.1 : -0.1), 0), 1)
        }
    }
}

/// Before/after from still images, used for screenshots.
struct StillPreview: View {
    let still: AppModel.Still
    let split: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(nsImage: still.before).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                Image(nsImage: still.after).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    .mask(HStack(spacing: 0) {
                        Color.clear.frame(width: proxy.size.width * split)
                        Color.black
                    })
            }
        }
    }
}
