import CoreGraphics
import Foundation

/// The app icon: the engraved eye in paper ink on a moss-green plate with a
/// fine metallic flake, in the macOS rounded-square shape and margin.
public enum AppIconArt {
    public static func draw(in ctx: CGContext, size: CGFloat) {
        let inset = size * 0.0977          // 100/1024: Apple's icon grid margin
        let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let shape = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.02, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(Palette.green)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        // A soft vertical sheen, darker on the left like the reference's folded metal.
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05),
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06),
        ] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
        if size >= 64 { Flake.draw(in: ctx, rect: rect, density: 0.9, seed: 7) }
        let small = size < 64
        let weight = max(1, 160 / size)
        EngravedEye.draw(in: ctx, center: CGPoint(x: size / 2, y: size / 2), radius: rect.width * (small ? 0.5 : 0.4),
                         style: .init(ink: Palette.paper, paper: Palette.green, medallion: !small,
                                      weight: small ? weight * 0.8 : max(1, 128 / size), detail: size >= 128))
        ctx.restoreGState()
    }
}

/// Metallic flake: sparse light and dark specks, deterministic per seed.
public enum Flake {
    public static func draw(in ctx: CGContext, rect: CGRect, density: CGFloat = 1, seed: UInt64 = 1) {
        var rng = SplitMix(seed: seed)
        let count = Int(rect.width * rect.height / 90 * density)
        let dot = max(0.6, rect.width / 700)
        for _ in 0..<count {
            let x = rect.minX + CGFloat(rng.next01()) * rect.width
            let y = rect.minY + CGFloat(rng.next01()) * rect.height
            let light = rng.next01() > 0.45
            let a = CGFloat(0.05 + rng.next01() * 0.12)
            ctx.setFillColor(light ? CGColor(srgbRed: 0.9, green: 1, blue: 0.7, alpha: a) : CGColor(srgbRed: 0.1, green: 0.14, blue: 0, alpha: a))
            let d = dot * CGFloat(0.6 + rng.next01())
            ctx.fill(CGRect(x: x, y: y, width: d, height: d))
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func next01() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
