import CoreGraphics
import Foundation

/// Mirada's mark: an eye inside a mirror medallion, drawn as fine engraved
/// lines (hatched iris, crease lines, ticked rim). Pure CoreGraphics so the
/// app, the icon renderer and the camera extension share one drawing.
public enum EngravedEye {
    public struct Style: Sendable {
        /// Line colour.
        public var ink: CGColor
        /// Colour behind the mark, used for the catch-light and the gap around
        /// the pupil. Nil leaves those transparent-free (no catch-light).
        public var paper: CGColor?
        /// 0 = just the eye, 1 = full medallion.
        public var medallion: Bool
        /// How open the eye is, 0 (closed) to 1. Drives the lock animation.
        public var openness: CGFloat
        /// Pupil offset as a fraction of the iris radius, for "looking" states.
        public var gaze: CGVector
        /// Line-width multiplier. Small renders (icons under 64 px) need heavier lines.
        public var weight: CGFloat
        /// Hatching, lashes and creases. Off for tiny renders, where they turn to mush.
        public var detail: Bool

        public init(ink: CGColor, paper: CGColor? = nil, medallion: Bool = true, openness: CGFloat = 1, gaze: CGVector = .zero,
                    weight: CGFloat = 1, detail: Bool = true) {
            self.ink = ink
            self.paper = paper
            self.medallion = medallion
            self.openness = openness
            self.gaze = gaze
            self.weight = weight
            self.detail = detail
        }
    }

    /// Draws centred at `center` with outer radius `radius`. Set `flipped` when
    /// the context's y axis points down (SwiftUI, AppKit flipped views).
    public static func draw(in ctx: CGContext, center: CGPoint, radius: CGFloat, ink: CGColor, flipped: Bool = false) {
        draw(in: ctx, center: center, radius: radius, style: Style(ink: ink), flipped: flipped)
    }

    public static func draw(in ctx: CGContext, center: CGPoint, radius: CGFloat, style: Style, flipped: Bool = false) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: radius, y: flipped ? -radius : radius)   // unit space, +y up
        ctx.setStrokeColor(style.ink)
        ctx.setFillColor(style.ink)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let w = style.weight

        if style.medallion { medallion(ctx, weight: w) }

        let open = max(0, min(1, style.openness))
        let half: CGFloat = 0.66
        let upper = 0.60 * max(open, 0.04), lower = 0.44 * max(open, 0.04)

        // Crease lines above the upper lid, like burin cuts.
        for i in 1...3 where style.detail {
            let lift = CGFloat(i) * 0.075
            ctx.setLineWidth((0.014 - CGFloat(i) * 0.002) * w)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: -half + 0.08 * CGFloat(i), y: 0.05 + lift * 0.4))
            ctx.addQuadCurve(to: CGPoint(x: half - 0.08 * CGFloat(i), y: 0.05 + lift * 0.4), control: CGPoint(x: 0, y: upper + lift + 0.06))
            ctx.strokePath()
        }

        // The almond.
        let almond = CGMutablePath()
        almond.move(to: CGPoint(x: -half, y: 0))
        almond.addQuadCurve(to: CGPoint(x: half, y: 0), control: CGPoint(x: 0, y: upper))
        almond.addQuadCurve(to: CGPoint(x: -half, y: 0), control: CGPoint(x: 0, y: -lower))
        almond.closeSubpath()

        if open > 0.08 {
            ctx.saveGState()
            ctx.addPath(almond)
            ctx.clip()
            iris(ctx, style: style)
            // Lower-lid shadow hatching.
            ctx.setLineWidth(0.006 * w)
            for k in 0..<(style.detail ? 7 : 0) {
                let y = -lower * 0.55 + CGFloat(k) * 0.03
                ctx.beginPath()
                ctx.move(to: CGPoint(x: -half * 0.9, y: y - 0.12))
                ctx.addLine(to: CGPoint(x: -half * 0.55, y: y - 0.05))
                ctx.move(to: CGPoint(x: half * 0.55, y: y - 0.05))
                ctx.addLine(to: CGPoint(x: half * 0.9, y: y - 0.12))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }

        ctx.setLineWidth(0.034 * w)
        ctx.addPath(almond)
        ctx.strokePath()

        // Lashes: short tapered strokes along the upper lid.
        ctx.setLineWidth(0.012 * w)
        for k in 0..<(style.detail ? 9 : 0) {
            let t = 0.18 + CGFloat(k) * 0.08
            let p = quad(CGPoint(x: -half, y: 0), CGPoint(x: 0, y: upper), CGPoint(x: half, y: 0), t)
            let dir = CGVector(dx: (t - 0.5) * 0.5, dy: 1)
            let len = 0.07 * (1 - abs(t - 0.5))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: p.x, y: p.y + 0.01))
            ctx.addLine(to: CGPoint(x: p.x + dir.dx * len, y: p.y + 0.01 + dir.dy * len))
            ctx.strokePath()
        }
    }

    private static func iris(_ ctx: CGContext, style: Style) {
        let c = CGPoint(x: style.gaze.dx * 0.1, y: 0.03 + style.gaze.dy * 0.08)
        let r: CGFloat = 0.27, pupil: CGFloat = style.detail ? 0.105 : 0.13
        let w = style.weight
        ctx.setLineWidth(0.02 * w)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.setLineWidth(0.007 * w)
        if style.detail {
            ctx.strokeEllipse(in: CGRect(x: c.x - r * 0.74, y: c.y - r * 0.74, width: 2 * r * 0.74, height: 2 * r * 0.74))
        }
        // Radial hatching, alternating lengths.
        for k in 0..<(style.detail ? 64 : 0) {
            let a = CGFloat(k) / 64 * 2 * .pi
            let inner = pupil + 0.02, outer = r * (k % 2 == 0 ? 0.97 : 0.8)
            ctx.setLineWidth((k % 2 == 0 ? 0.0065 : 0.0045) * w)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
            ctx.strokePath()
        }
        // The pupil takes the darker colour and the catch-light the lighter, so
        // the eye reads correctly in light-on-dark and dark-on-light.
        let pupilRect = CGRect(x: c.x - pupil, y: c.y - pupil, width: 2 * pupil, height: 2 * pupil)
        let paper = style.paper
        let (dark, light) = paper.map { luminance(style.ink) < luminance($0) ? (style.ink, $0) : ($0, style.ink) } ?? (style.ink, nil)
        ctx.setFillColor(dark)
        ctx.fillEllipse(in: pupilRect)
        ctx.setLineWidth(0.014 * w)
        ctx.strokeEllipse(in: pupilRect)
        if let light {
            ctx.setFillColor(light)
            let h: CGFloat = 0.032
            ctx.fillEllipse(in: CGRect(x: c.x + 0.045 - h, y: c.y + 0.05 - h, width: 2 * h, height: 2 * h))
        }
        ctx.setFillColor(style.ink)
    }

    private static func medallion(_ ctx: CGContext, weight w: CGFloat) {
        ctx.setLineWidth(0.022 * w)
        ctx.strokeEllipse(in: CGRect(x: -0.98, y: -0.98, width: 1.96, height: 1.96))
        ctx.setLineWidth(0.01 * w)
        ctx.strokeEllipse(in: CGRect(x: -0.86, y: -0.86, width: 1.72, height: 1.72))
        for k in 0..<72 {
            let a = CGFloat(k) / 72 * 2 * .pi
            let long = k % 6 == 0
            let r0: CGFloat = long ? 0.865 : 0.885, r1: CGFloat = long ? 0.97 : 0.945
            ctx.setLineWidth((long ? 0.012 : 0.007) * w)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cos(a) * r0, y: sin(a) * r0))
            ctx.addLine(to: CGPoint(x: cos(a) * r1, y: sin(a) * r1))
            ctx.strokePath()
        }
    }

    static func luminance(_ c: CGColor) -> CGFloat {
        guard let rgb = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, rgb.count >= 3 else { return 0.5 }
        return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    }

    private static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}
