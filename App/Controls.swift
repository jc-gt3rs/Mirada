import AppKit
import MiradaArt
import SwiftUI

/// A thin engraved-style slider: hairline track, green fill, round thumb.
/// Drawn in SwiftUI so it matches the theme and renders in snapshots.
struct GreenSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step = 0.05
    var label: String
    var valueText: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(height: 3)
                Capsule().fill(Theme.green).frame(width: max(3, w * f), height: 3)
                ForEach(0..<11) { i in
                    Rectangle().fill(Theme.inkFaint).frame(width: 1, height: i % 5 == 0 ? 7 : 4)
                        .offset(x: w * CGFloat(i) / 10 - 0.5, y: 8)
                }
                Circle()
                    .fill(Theme.card)
                    .overlay(Circle().strokeBorder(Theme.green, lineWidth: 2))
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(x: w * f - 8)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let raw = range.lowerBound + Double(min(max(g.location.x / max(w, 1), 0), 1)) * (range.upperBound - range.lowerBound)
                value = (raw / step).rounded() * step
            })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText(value))
        .accessibilityAdjustableAction { dir in
            let next = value + (dir == .increment ? step : -step)
            value = min(max(next, range.lowerBound), range.upperBound)
        }
    }
}

/// Mono chips that act as a segmented control: `:live:` `:file:`.
struct ChipPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var onBand = false
    var label: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, text in
                let on = option == selection
                Button { selection = option } label: {
                    Text(text)
                        .font(.tag)
                        .tracking(0.6)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(on ? (onBand ? Theme.band : Theme.card) : (onBand ? Theme.onBand : Theme.inkSoft))
                        .background(Capsule().fill(on ? (onBand ? Theme.onBand : Theme.green) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(text.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().strokeBorder(onBand ? Theme.onBand.opacity(0.45) : Theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// An on/off switch drawn as a small engraved capsule.
struct PillToggle: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.green : Theme.line).frame(width: 30, height: 18)
                Circle().fill(Theme.card).frame(width: 14, height: 14).padding(2)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            }
            .animation(.snappy(duration: 0.18), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isButton)
    }
}

/// Filled green button for the main action in a panel.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, design: .monospaced).weight(.semibold))
            .foregroundStyle(Theme.onBand)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.green.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
    }
}

/// Bordered secondary button.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.note)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.line : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// A chip that pops up an AppKit menu, so the chip itself stays a pure
/// SwiftUI drawing.
struct MenuChip: View {
    let title: String
    let items: [(id: String, title: String)]
    let selected: String
    let onSelect: (String) -> Void
    var label: String

    var body: some View {
        Button {
            let menu = NSMenu()
            for item in items {
                let mi = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                mi.state = item.id == selected ? .on : .off
                mi.representedObject = item.id
                menu.addItem(mi)
            }
            let target = MenuTarget(onSelect)
            for mi in menu.items {
                mi.target = target
                mi.action = #selector(MenuTarget.pick(_:))
            }
            objc_setAssociatedObject(menu, &MenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.mono)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }

    final class MenuTarget: NSObject {
        nonisolated(unsafe) static var key = 0
        let onSelect: (String) -> Void
        init(_ onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }
        @objc func pick(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onSelect(id) } }
    }
}

/// The band's metallic flake, drawn once per size.
struct FlakeTexture: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.withCGContext { cg in Flake.draw(in: cg, rect: CGRect(origin: .zero, size: size), density: 0.8, seed: 3) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
