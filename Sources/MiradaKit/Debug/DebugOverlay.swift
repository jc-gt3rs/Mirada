import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// What the pipeline decided for one frame, for the debug overlay.
public struct DebugInfo: Sendable {
    public var face: FaceLandmarks?
    public var state: FaceState
    public var fade: Double
    public var strength: Double
    public var enabled: Bool
    /// Applied correction (after clamp, strength and fade).
    public var angle: GazeAngle?
    /// Needed angle before clamp, strength and fade.
    public var rawAngle: GazeAngle?
    /// Where you look relative to the middle of the screen (nil: not estimated).
    public var gaze: GazeAngle?
    /// The middle comes from calibration (true) or is learned (false).
    public var gazeCalibrated = false
    /// Focal length in use, its source, and the resulting distance.
    public var focal: String?
    /// How the face was found: detect, track, refresh, idle.
    public var trackerMode: String
    public var visionMs: Double
    public var modelMs: Double
    public var composeMs: Double
}

/// Draws the pipeline's decisions into a BGRA frame: face box, the six eye
/// points per eye, the 64x48 model crops, the correction arrow, and a
/// readout. Everything is drawn in upright coordinates, so it reads
/// correctly in rotated file frames too.
public enum DebugOverlay {
    public static func draw(_ info: DebugInfo, into pb: CVPixelBuffer, mapping: UprightMapping) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // Top-left origin, then upright -> buffer.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let m = mapping.uprightToBuffer.map(CGFloat.init)
        ctx.concatenate(CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5]))

        let uw = CGFloat(mapping.uprightWidth), uh = CGFloat(mapping.uprightHeight)
        let s = max(0.6, min(uw, uh) / 720)
        let color = stateColor(info)

        if let face = info.face {
            // Face box from Vision.
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2 * s)
            ctx.stroke(face.bounds)
            label(info.trackerMode, at: CGPoint(x: face.bounds.minX, y: face.bounds.minY - 6 * s), size: 11 * s, color: color, in: ctx)

            for eye in [face.leftEye, face.rightEye] {
                // The crop the model sees.
                if let crop = EyeCrop.make(eye, frameWidth: Int(uw), frameHeight: Int(uh)) {
                    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
                    ctx.setLineWidth(1.2 * s)
                    ctx.setLineDash(phase: 0, lengths: [4 * s, 3 * s])
                    ctx.stroke(CGRect(x: crop.left, y: crop.top, width: crop.width, height: crop.height))
                    ctx.setLineDash(phase: 0, lengths: [])
                }
                // Contour and the six training-order points.
                let pts = eye.ordered
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
                ctx.setLineWidth(1 * s)
                ctx.addLines(between: pts + [pts[0]])
                ctx.strokePath()
                for (i, p) in pts.enumerated() {
                    ctx.setFillColor(pointColor(i))
                    let r = 2.4 * s
                    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                }
            }
            // Pupils: white rings.
            for p in [face.leftPupil, face.rightPupil].compactMap({ $0 }) {
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
                ctx.setLineWidth(1.5 * s)
                let r = 3.5 * s
                ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }

            // Correction arrow from between the eyes: up for a camera above.
            if let a = info.angle {
                let c = CGPoint(x: (face.leftEye.center.x + face.rightEye.center.x) / 2, y: (face.leftEye.center.y + face.rightEye.center.y) / 2)
                let k = 3 * s
                let tip = CGPoint(x: c.x + CGFloat(a.horizontal) * k, y: c.y - CGFloat(a.vertical) * k)
                ctx.setStrokeColor(Palette.amber)
                ctx.setLineWidth(2 * s)
                ctx.move(to: c)
                ctx.addLine(to: tip)
                ctx.strokePath()
                ctx.setFillColor(Palette.amber)
                ctx.fillEllipse(in: CGRect(x: tip.x - 3 * s, y: tip.y - 3 * s, width: 6 * s, height: 6 * s))
            }
        }

        readout(info, color: color, scale: s, in: ctx)
    }

    // MARK: pieces

    static func readout(_ i: DebugInfo, color: CGColor, scale s: CGFloat, in ctx: CGContext) {
        func deg(_ v: Double) -> String { String(format: "%+.1f°", v) }
        var lines = [":mirada: debug", "state   \(stateText(i))"]
        lines.append(String(format: "fade    %.2f   strength %.2f", i.fade, i.strength))
        if let a = i.angle, let r = i.rawAngle {
            lines.append("angle   V \(deg(a.vertical))  H \(deg(a.horizontal))   raw V \(deg(r.vertical)) H \(deg(r.horizontal))")
        } else if let r = i.rawAngle {
            lines.append("angle   none   raw V \(deg(r.vertical)) H \(deg(r.horizontal))")
        }
        if let g = i.gaze {
            lines.append("gaze    V \(deg(g.vertical))  H \(deg(g.horizontal))  from the middle (\(i.gazeCalibrated ? "calibrated" : "learned"))")
        } else {
            lines.append("gaze    assumed: middle of the screen")
        }
        if let f = i.face {
            let ear = (FaceGate.aspectRatio(f.leftEye) + FaceGate.aspectRatio(f.rightEye)) / 2
            lines.append(String(format: "head    yaw %@  pitch %@   eyes %.2f", deg(f.yaw ?? 0), deg(f.pitch ?? 0), ear))
            lines.append(String(format: "iod     %.0f px   box %@", f.interocularPixels, i.trackerMode))
            if let focal = i.focal { lines.append("lens    \(focal)") }
        } else {
            lines.append("box     \(i.trackerMode)")
        }
        lines.append(String(format: "ms      vision %.1f  model %.1f  compose %.1f", i.visionMs, i.modelMs, i.composeMs))

        let size = 12 * s, lead = size * 1.35
        let panel = CGRect(x: 10 * s, y: 10 * s, width: 400 * s, height: lead * CGFloat(lines.count) + 12 * s)
        ctx.setFillColor(CGColor(srgbRed: 0.035, green: 0.043, blue: 0.122, alpha: 0.72))
        ctx.fill(panel)
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: panel.minX, y: panel.minY, width: 3 * s, height: panel.height))
        for (n, line) in lines.enumerated() {
            label(line, at: CGPoint(x: panel.minX + 10 * s, y: panel.minY + 6 * s + lead * CGFloat(n + 1) - 4 * s), size: size,
                  color: n == 0 ? Palette.greenOnNight : Palette.paper, in: ctx)
        }
    }

    static func label(_ text: String, at p: CGPoint, size: CGFloat, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // the context is y-down
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func stateText(_ i: DebugInfo) -> String {
        guard i.enabled else { return "correction off" }
        switch i.state {
        case .tracking: return i.fade > 0.9 ? "gaze locked" : "locking on"
        case .blinking: return "blink (fading out)"
        case .lookingAway: return "looking away (paused)"
        case .tooSmall: return "face too small"
        case .noFace: return "no face"
        }
    }

    static func stateColor(_ i: DebugInfo) -> CGColor {
        switch i.state {
        case .tracking: return i.fade > 0.9 && i.enabled ? Palette.amber : Palette.greenOnNight
        case .blinking: return CGColor(srgbRed: 0.4, green: 0.7, blue: 1, alpha: 1)
        case .lookingAway, .tooSmall: return CGColor(srgbRed: 1, green: 0.35, blue: 0.35, alpha: 1)
        case .noFace: return CGColor(gray: 0.7, alpha: 1)
        }
    }

    static func pointColor(_ i: Int) -> CGColor {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.25, 0.25), (1, 0.6, 0.1), (1, 0.95, 0.2), (0.3, 1, 0.3), (0.2, 0.85, 1), (0.7, 0.45, 1)]
        let c = colors[i % 6]
        return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }
}

/// Colours shared with MiradaArt's palette (MiradaKit doesn't link it).
enum Palette {
    static let amber = CGColor(srgbRed: 1.0, green: 0.62, blue: 0.24, alpha: 1)
    static let greenOnNight = CGColor(srgbRed: 0.616, green: 0.729, blue: 0.271, alpha: 1)
    static let paper = CGColor(srgbRed: 0.957, green: 0.941, blue: 0.902, alpha: 1)
}
