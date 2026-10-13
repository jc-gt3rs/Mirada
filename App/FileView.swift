import AppKit
import MiradaKit
import SwiftUI
import UniformTypeIdentifiers

struct FilePanel: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(spacing: 10) {
                    MarkView(openness: isRunning ? 1 : 0.7, ink: targeted ? Theme.green : Theme.inkSoft, paper: Theme.card)
                        .frame(width: 84, height: 84)
                    Text(title).font(.mono).foregroundStyle(Theme.ink).multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle)
                    Text(subtitle).font(.note).foregroundStyle(Theme.inkSoft).multilineTextAlignment(.center)
                    Button("choose…") { choose() }.buttonStyle(QuietButtonStyle())
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .aspectRatio(Theme.previewRatio, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius - 4)
                        .strokeBorder(targeted ? Theme.green : Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .padding(8)
                )
            }
            .modifier(FileDrop(enabled: !model.isSnapshot, targeted: $targeted) { model.chooseFile($0) })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Drop a video or photo here")

            switch model.fileState {
            case .running(_, let p):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Tag("progress")
                        Spacer()
                        Text(eta(p)).font(.mono).foregroundStyle(Theme.inkSoft)
                    }
                    ProgressBar(fraction: p.fraction)
                    Button("cancel") { model.cancelFile() }.buttonStyle(QuietButtonStyle())
                }
            case .done(_, let output, let summary):
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary).font(.mono).foregroundStyle(Theme.green)
                    Button("show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }.buttonStyle(QuietButtonStyle())
                }
            case .failed(let why):
                Text("// \(why)").font(.mono).foregroundStyle(.red)
            default:
                EmptyView()
            }

            Button("save corrected copy") { model.saveCorrectedCopy() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSave)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityHint("Command S")
            Text("// audio is copied untouched · nothing leaves this Mac").font(.fine).foregroundStyle(Theme.inkFaint)
        }
    }

    private var isRunning: Bool { if case .running = model.fileState { true } else { false } }

    private var canSave: Bool { if case .ready = model.fileState { true } else { false } }

    private var title: String {
        switch model.fileState {
        case .ready(let url), .running(let url, _), .done(let url, _, _): url.lastPathComponent
        default: "#1 drop a video or photo"
        }
    }

    private var subtitle: String {
        switch model.fileState {
        case .ready: "#2 save a corrected copy"
        case .running: "// correcting"
        case .done: "// done"
        default: ":mp4: :mov: :jpg: :png: :heic:"
        }
    }

    private func eta(_ p: FileJobProgress) -> String {
        let pct = "\(Int(p.fraction * 100))%"
        guard let e = p.eta else { return pct }
        return pct + String(format: " · eta %d:%02d", Int(e) / 60, Int(e) % 60)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.chooseFile(url) }
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(Theme.green).frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Accepts a dropped file. Off for offscreen snapshots, whose renderer can't
/// draw the AppKit view that backs a drop target.
struct FileDrop: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let onFile: @MainActor (URL) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in onFile(url) } }
                }
                return true
            }
        } else {
            content
        }
    }
}
