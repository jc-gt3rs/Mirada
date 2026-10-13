import AppKit
import SwiftUI

@main
struct MiradaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        SelfTest.runIfRequested()
        Screenshots.runIfRequested()
    }

    var body: some Scene {
        Window("Mirada", id: "main") {
            ContentView()
                .environment(model)
                .modifier(RegisterReopen())
                // Width is the only free dimension: text stays its size, the
                // preview grows with the width at a fixed ratio, and the window's
                // height follows the content (no empty strip at the bottom).
                .frame(minWidth: WindowShape.minWidth, idealWidth: WindowShape.width, maxWidth: WindowShape.maxWidth)
                .fixedSize(horizontal: false, vertical: true)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: WindowShape.width, height: 600)
        .commands { MiradaCommands(model: model) }
    }
}

/// The menu bar. These work with the window closed: live correction (and the
/// virtual camera) keep running in the background.
struct MiradaCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Show Mirada Window") { openWindow(id: "main") }
                .keyboardShortcut("0", modifiers: .command)
        }
        CommandMenu("Correction") {
            Toggle("Correction", isOn: Binding(get: { model.settings.enabled }, set: { model.settings.enabled = $0 }))
                .keyboardShortcut("g", modifiers: .command)
            Toggle("Debug Overlay", isOn: Binding(get: { model.settings.debugOverlay }, set: { model.settings.debugOverlay = $0 }))
                .keyboardShortcut("d", modifiers: .command)
            Toggle("Follow Where I Look", isOn: Binding(get: { model.settings.followGaze }, set: { model.settings.followGaze = $0 }))
            Button("Recentre Gaze (I'm Looking at the Middle)") { model.recenterGaze() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Toggle("Send to Virtual Camera", isOn: Binding(get: { model.settings.publishVirtualCamera }, set: { model.settings.publishVirtualCamera = $0 }))
            Divider()
            Button("Live") { model.mode = .live }.keyboardShortcut("1", modifiers: .command)
            Button("File") { model.mode = .file }.keyboardShortcut("2", modifiers: .command)
            Button("Before or After") { model.showBefore.toggle() }.keyboardShortcut("b", modifiers: .command)
            Button("Calibrate…") { model.calibrationOpen = true; openWindow(id: "main") }.keyboardShortcut("k", modifiers: .command)
        }
    }
}

/// Window widths. Height always follows the content.
enum WindowShape {
    static let width: CGFloat = 380
    static let minWidth: CGFloat = 380
    static let maxWidth: CGFloat = 640
}

/// Lets the Dock icon reopen the window after it was closed.
struct RegisterReopen: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { AppDelegate.reopen = { openWindow(id: "main") } }
    }
}
