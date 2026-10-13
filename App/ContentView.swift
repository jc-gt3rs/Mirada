import MiradaKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HeaderBand(mode: $model.mode)
            Group {
                if model.mode == .live { LivePanel() } else { FilePanel() }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 14)
            .padding(.bottom, 14)
        }
        .background(Theme.paper.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .task { if model.mode == .live, !model.isSnapshot, !AppModel.isDiagnosticRun { model.startLive() } }
        .sheet(isPresented: $model.calibrationOpen) { CalibrationView().environment(model) }
    }
}

struct HeaderBand: View {
    @Binding var mode: AppModel.Mode

    var body: some View {
        HStack(spacing: 10) {
            MarkView(openness: 0.9, ink: Theme.onBand, paper: Theme.band)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: -2) {
                Text("mirada").font(.display(30)).foregroundStyle(Theme.onBand)
                Text("// look here").font(.tag).tracking(0.8).foregroundStyle(Theme.onBand.opacity(0.75))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mirada")
            .accessibilityAddTraits(.isHeader)
            Spacer()
            ChipPicker(selection: $mode, options: [(.live, ":live:"), (.file, ":file:")], onBand: true, label: "Mode")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background {
            ZStack {
                Theme.band
                FlakeTexture().opacity(0.9)
            }
        }
    }
}

/// The single drop-shadowed card everything sits on.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }
}
