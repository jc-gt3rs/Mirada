import CoreGraphics
import CoreText
import Foundation

/// The frame Mirada Camera shows when nothing is feeding it. y-up context.
public enum RestingCard {
    public static func draw(in ctx: CGContext, width w: CGFloat, height h: CGFloat) {
        ctx.setFillColor(Palette.night)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        EngravedEye.draw(in: ctx, center: CGPoint(x: w / 2, y: h * 0.57), radius: h * 0.21,
                         style: .init(ink: Palette.paper, paper: Palette.night, openness: 0.55))
        text(":mirada: // camera is resting", in: ctx, at: CGPoint(x: w / 2, y: h * 0.235), size: h * 0.038, color: Palette.paper)
        text("open Mirada to send your corrected video here", in: ctx, at: CGPoint(x: w / 2, y: h * 0.17), size: h * 0.026, color: Palette.greenOnNight)
    }

    static func text(_ s: String, in ctx: CGContext, at p: CGPoint, size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: p.x - bounds.width / 2, y: p.y)
        CTLineDraw(line, ctx)
    }
}

/// Mirada's colours, shared by artwork rendered outside SwiftUI.
public enum Palette {
    /// Moss green, the signature colour (sampled from JC's reference, median #698129).
    public static let green = CGColor(srgbRed: 0.412, green: 0.506, blue: 0.161, alpha: 1)      // #698129
    /// Darker green for strokes and text on paper.
    public static let greenInk = CGColor(srgbRed: 0.310, green: 0.392, blue: 0.125, alpha: 1)   // #4F6420
    /// Brighter green that reads on dark backgrounds.
    public static let greenOnNight = CGColor(srgbRed: 0.616, green: 0.729, blue: 0.271, alpha: 1) // #9DBA45
    /// Off-white paper.
    public static let paper = CGColor(srgbRed: 0.957, green: 0.941, blue: 0.902, alpha: 1)      // #F4F0E6
    /// Ink on paper.
    public static let ink = CGColor(srgbRed: 0.055, green: 0.063, blue: 0.157, alpha: 1)        // #0E1028
    /// Dark background.
    public static let night = CGColor(srgbRed: 0.035, green: 0.043, blue: 0.122, alpha: 1)      // #090B1F
    /// Warm accent for "gaze locked".
    public static let amber = CGColor(srgbRed: 1.0, green: 0.62, blue: 0.24, alpha: 1)          // #FF9E3D
}
