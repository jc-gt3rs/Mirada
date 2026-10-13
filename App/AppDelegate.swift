import AppKit
import MiradaKit
import os

/// Keeps Mirada running when its window closes (live correction and the
/// virtual camera carry on), reopens the window from the Dock, and keeps
/// App Nap from throttling live processing in the background.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the window scene so the Dock icon can bring the window back.
    @MainActor static var reopen: (() -> Void)?
    private var activity: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { Self.reopen?() } }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        VirtualCameraProbe.runIfRequested()
        // Hidden: `--window-scale S` resizes the window (layout test).
        if let i = CommandLine.arguments.firstIndex(of: "--window-scale"), i + 1 < CommandLine.arguments.count,
           let sc = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let w = NSApp.windows.first(where: { $0.isVisible }) else { return }
                w.setContentSize(NSSize(width: WindowShape.width * sc, height: w.contentLayoutRect.height))
            }
        }
        // Hidden: `--close-window-after N` (lifecycle test).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--close-window-after"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                NSApp.windows.filter { $0.isVisible }.forEach { $0.performClose(nil) }
                Logger(subsystem: "com.jcantor.mirada", category: "app").info("test: closed the window")
            }
        }
        // Live video is user-visible work even with no window on screen.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Live gaze correction for the virtual camera")
    }
}

/// `open -n Mirada.app --args --probe-virtual-camera` reads the virtual
/// camera the way another app (Photo Booth, Zoom) would, without publishing
/// anything, logs what arrives, and quits. Run it while Mirada is live.
enum VirtualCameraProbe {
    @MainActor
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--probe-virtual-camera") else { return }
        let log = Logger(subsystem: "com.jcantor.mirada", category: "probe")
        Task.detached {
            var devices = VirtualCameraTarget.available().compactMap { t in CameraDevices.list().first { $0.name == t.deviceName } }
            if let physical = CameraDevices.list().first(where: { !$0.isVirtual }) { devices.append(physical) }
            for device in devices {
                let target = (name: device.name, rawValue: device.name)
                let camera = CameraSource(config: CameraSource.Config(deviceID: device.id))
                let stats = OSAllocatedUnfairLock(initialState: (frames: 0, means: [Double]()))
                let reader = Task.detached {
                    do {
                        for try await frame in camera.frames() {
                            let luma = meanLuma(frame.pixelBuffer)
                            stats.withLock { s in
                                s.frames += 1
                                if s.frames % 10 == 1 { s.means.append(luma) }
                            }
                        }
                    } catch {
                        log.error("probe \(target.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                reader.cancel()
                camera.stop()
                let (frames, means) = stats.withLock { ($0.frames, $0.means) }
                let spread = (means.max() ?? 0) - (means.min() ?? 0)
                log.info("probe \(target.name, privacy: .public): \(frames) frames in 3 s, mean luma \(means.first ?? -1, format: .fixed(precision: 1))..\(means.last ?? -1, format: .fixed(precision: 1)), spread \(spread, format: .fixed(precision: 1))")
            }
            exit(0)
        }
    }

    static func meanLuma(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return -1 }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        var sum = 0.0, n = 0.0
        for y in Swift.stride(from: 0, to: h, by: 16) {
            for x in Swift.stride(from: 0, to: w, by: 16) {
                let p = base + y * stride + x * 4
                sum += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                n += 1
            }
        }
        return sum / max(n, 1)
    }
}
