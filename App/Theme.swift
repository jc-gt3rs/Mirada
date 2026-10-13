import AppKit
import MiradaArt
import SwiftUI

/// Mirada's design tokens. Light is paper and ink under a band of moss
/// green (JC's reference: a metallic olive, median #698129); dark is
/// ink-night with a brighter green. One warm accent (amber) means
/// "gaze locked" and nothing else.
enum Theme {
    static let paper = dynamic(light: 0xF4F0E6, dark: 0x090B1F)
    static let card = dynamic(light: 0xFBF9F3, dark: 0x111430)
    static let ink = dynamic(light: 0x0E1028, dark: 0xF4F0E6)
    static let inkSoft = dynamic(light: 0x0E1028, dark: 0xF4F0E6, alpha: 0.62)
    static let inkFaint = dynamic(light: 0x0E1028, dark: 0xF4F0E6, alpha: 0.38)
    static let line = dynamic(light: 0x0E1028, dark: 0xF4F0E6, alpha: 0.14)
    /// The signature colour for text and controls: darkened on paper for 5.8:1
    /// contrast, brightened on night for 8.9:1.
    static let green = dynamic(light: 0x4F6420, dark: 0x9DBA45)
    /// The header band: the reference green itself, a shade deeper in dark mode.
    static let band = dynamic(light: 0x698129, dark: 0x55691F)
    static let onBand = Color(hex: 0xF4F0E6)
    static let amber = Color(hex: 0xFF9E3D)
    static let night = Color(hex: 0x090B1F)

    static let radius: CGFloat = 14
    /// Preview width:height, constant at every window width (about 5:4).
    static let previewRatio: CGFloat = 348.0 / 280.0
    static let gutter: CGFloat = 16

    static func dynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }
}

extension Font {
    /// Condensed, light display type for the wordmark and big numbers.
    static func display(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// Small mono labels: `#1 STRENGTH`, `:live:`.
    static let tag = Font.system(size: 12, weight: .semibold, design: .monospaced)
    /// Values and body copy.
    static let mono = Font.system(size: 13, design: .monospaced)
    /// Secondary lines (status, explanations).
    static let note = Font.system(size: 12, design: .monospaced)
    /// Fine print (hints, the latency line).
    static let fine = Font.system(size: 11, design: .monospaced)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// `#1 STRENGTH`-style section label.
struct Tag: View {
    let number: Int?
    let text: String

    init(_ number: Int?, _ text: String) {
        self.number = number
        self.text = text
    }

    init(_ text: String) {
        self.init(nil, text)
    }

    var body: some View {
        HStack(spacing: 4) {
            if let number { Text("#\(number)").foregroundStyle(Theme.green) }
            Text(text.uppercased()).foregroundStyle(Theme.inkSoft)
        }
        .font(.tag)
        .tracking(1.1)
        .accessibilityElement(children: .combine)
    }
}

/// The engraved eye as a SwiftUI view. `openness` and `gaze` animate.
struct MarkView: View, Animatable {
    var openness: CGFloat = 1
    var gaze: CGVector = .zero
    var ink: Color = Theme.ink
    var paper: Color? = Theme.paper
    var medallion = true

    nonisolated var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(openness, AnimatablePair(gaze.dx, gaze.dy)) }
        set {
            openness = newValue.first
            gaze = CGVector(dx: newValue.second.first, dy: newValue.second.second)
        }
    }

    @Environment(\.self) private var environment

    var body: some View {
        Canvas { ctx, size in
            let inkCG = ink.resolve(in: environment).cgColor
            let paperCG = paper.map { $0.resolve(in: environment).cgColor }
            let r = min(size.width, size.height) / 2
            ctx.withCGContext { cg in
                EngravedEye.draw(in: cg, center: CGPoint(x: size.width / 2, y: size.height / 2), radius: r * 0.98,
                                 style: .init(ink: inkCG, paper: paperCG, medallion: medallion, openness: openness, gaze: gaze,
                                              weight: max(1, 48 / max(r, 1)), detail: r > 18),
                                 flipped: true)
            }
        }
        .accessibilityHidden(true)
    }
}
