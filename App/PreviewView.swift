import AppKit
import os
import CoreVideo
import SwiftUI

/// Hands the newest pixel buffer to a CALayer without copying: the layer
/// displays the buffer's IOSurface directly.
final class PreviewFeed: @unchecked Sendable {
    let layer = CALayer()
    private let lock = NSLock()
    private var pending: CVPixelBuffer?

    init() {
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
    }

    func show(_ buffer: CVPixelBuffer) {
        let wasEmpty = lock.withLock {
            let empty = pending == nil
            pending = buffer
            return empty
        }
        guard wasEmpty else { return }
        DispatchQueue.main.async { [self] in
            let next = lock.withLock { () -> CVPixelBuffer? in
                defer { pending = nil }
                return pending
            }
            guard let next, let surface = CVPixelBufferGetIOSurface(next)?.takeUnretainedValue() else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
        }
    }

    func clear() {
        DispatchQueue.main.async { [layer] in layer.contents = nil }
    }
}

/// Before/after preview. `split` is the fraction of the width (in view
/// coordinates, left to right) that shows the original.
struct PreviewView: NSViewRepresentable {
    let after: PreviewFeed
    let before: PreviewFeed
    var split: CGFloat
    var mirrored = true

    /// Lays its layers out in `layout()`, so they always match the view's real
    /// bounds (sizing them only on SwiftUI updates left them at a stale or
    /// zero size until something else changed: a black or off-centre picture).
    final class Host: NSView {
        let afterMask = CALayer()
        let afterClip = CALayer()
        var feeds: (after: PreviewFeed, before: PreviewFeed)?
        var split: CGFloat = 0.5 { didSet { needsLayout = true } }
        var mirrored = true { didSet { needsLayout = true } }

        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }

        override func layout() {
            super.layout()
            if CommandLine.arguments.contains("--layout-log"), let w = window {
                Logger(subsystem: "com.jcantor.mirada", category: "layout")
                    .info("preview \(NSStringFromRect(self.convert(self.bounds, to: nil)), privacy: .public) bounds \(NSStringFromSize(self.bounds.size), privacy: .public) window \(NSStringFromSize(w.contentLayoutRect.size), privacy: .public)")
            }
            guard let feeds else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let b = bounds
            for l in [feeds.before.layer, feeds.after.layer] {
                l.setAffineTransform(.identity)
                l.bounds = CGRect(origin: .zero, size: b.size)
                l.position = CGPoint(x: b.midX, y: b.midY)
                l.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            }
            afterClip.frame = b
            let x = b.width * min(max(split, 0), 1)
            afterMask.frame = CGRect(x: x, y: 0, width: b.width - x, height: b.height)
            CATransaction.commit()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }
    }

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        view.layer = root
        root.addSublayer(before.layer)
        view.afterClip.addSublayer(after.layer)
        view.afterMask.backgroundColor = NSColor.black.cgColor
        view.afterClip.mask = view.afterMask
        root.addSublayer(view.afterClip)
        view.feeds = (after, before)
        view.split = split
        view.mirrored = mirrored
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        view.split = split
        view.mirrored = mirrored
    }
}
