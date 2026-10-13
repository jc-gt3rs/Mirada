import AVFoundation
import CoreVideo
import Foundation
import os

/// End-to-end check of a virtual camera: push a solid colour into its sink
/// and read it back through the camera side, like a video call app would.
/// Needs camera permission (it opens the virtual camera as a camera).
public enum VirtualCameraLoopback {
    public struct Result: Sendable, Codable {
        public let target: VirtualCameraTarget
        public let sent: Int
        public let received: Int
        public let matching: Int
        public var ok: Bool { matching > 0 }
    }

    public static func run(_ target: VirtualCameraTarget, seconds: Double = 3) async throws -> Result {
        let client = try CMIOSinkClient(target: target)
        try client.start()
        defer { client.stop() }

        let pattern = try solidFrame(width: client.width, height: client.height)
        guard let device = CameraDevices.discovery().devices.first(where: { $0.localizedName == target.deviceName }) else {
            throw MiradaError.virtualCameraUnavailable("\(target.deviceName) is not visible as a camera")
        }
        let camera = CameraSource(config: CameraSource.Config(deviceID: device.uniqueID))
        let counts = OSAllocatedUnfairLock(initialState: (0, 0))

        let pusher = Task.detached {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !Task.isCancelled {
                client.send(pattern)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        defer { pusher.cancel() }

        // Read until the deadline, even if the camera side never delivers a frame.
        let reader = Task.detached { () -> (Int, Int) in
            var received = 0, matching = 0
            do {
                for try await frame in camera.frames() {
                    if Task.isCancelled { break }
                    received += 1
                    if isMagenta(frame.pixelBuffer) { matching += 1 }
                    let snapshot = (received, matching)
                    counts.withLock { $0 = snapshot }
                }
            } catch {}
            return (received, matching)
        }
        try? await Task.sleep(nanoseconds: UInt64((seconds + 1) * 1e9))
        reader.cancel()
        camera.stop()
        let (received, matching) = counts.withLock { $0 }
        return Result(target: target, sent: client.sent, received: received, matching: matching)
    }

    static func solidFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else {
            throw MiradaError.internalError("test frame")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: CVPixelBufferGetBytesPerRow(pb) * height, by: 4) {
            p[i] = 255; p[i + 1] = 0; p[i + 2] = 255; p[i + 3] = 255   // BGRA magenta
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    static func isMagenta(_ pb: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let p = base + (CVPixelBufferGetHeight(pb) / 2) * CVPixelBufferGetBytesPerRow(pb) + (CVPixelBufferGetWidth(pb) / 2) * 4
        return p[0] > 200 && p[1] < 60 && p[2] > 200
    }
}
