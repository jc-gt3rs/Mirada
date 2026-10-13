import CoreGraphics
import Foundation
import ImageIO
import MiradaArt
import UniformTypeIdentifiers

// Usage:
//   mirada-art resting <out.png>               the Mirada Camera placeholder (1280x720)
//   mirada-art icon <AppIcon.appiconset>       every macOS icon size
//   mirada-art mark <out.png> <size> [light|dark]
func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ ctx: CGContext, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
switch args.count > 2 ? args[1] : "" {
case "resting":
    let ctx = bitmap(1280, 720)
    RestingCard.draw(in: ctx, width: 1280, height: 720)
    write(ctx, args[2])
case "icon":
    let dir = args[2]
    for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
        for scale in scales {
            let px = points * scale
            let ctx = bitmap(px, px)
            AppIconArt.draw(in: ctx, size: CGFloat(px))
            write(ctx, "\(dir)/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png")
        }
    }
case "mark":
    let size = Int(args[3]) ?? 512
    let ctx = bitmap(size, size)
    let dark = args.count > 4 && args[4] == "dark"
    ctx.setFillColor(dark ? Palette.night : Palette.paper)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    EngravedEye.draw(in: ctx, center: CGPoint(x: size / 2, y: size / 2), radius: CGFloat(size) * 0.45,
                     style: .init(ink: dark ? Palette.paper : Palette.greenInk, paper: dark ? Palette.night : Palette.paper))
    write(ctx, args[2])
default:
    FileHandle.standardError.write(Data("usage: mirada-art resting|icon|mark <path> ...\n".utf8))
    exit(64)
}
