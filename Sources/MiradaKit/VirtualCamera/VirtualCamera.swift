import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os
import VideoToolbox

/// Where corrected frames can be published.
public enum VirtualCameraTarget: String, Sendable, Codable, CaseIterable {
    /// Mirada's own CoreMediaIO camera extension.
    case mirada
    /// The sink stream of an installed OBS Virtual Camera (works without a paid developer team).
    case obs

    public var deviceName: String {
        switch self {
        case .mirada: "Mirada Camera"
        case .obs: "OBS Virtual Camera"
        }
    }

    /// Targets whose device is installed and exposes a sink stream, best first.
    public static func available() -> [VirtualCameraTarget] {
        let devices = CMIO.devices()
        return allCases.filter { t in devices.contains { $0.name == t.deviceName && $0.streams.contains(where: \.isSink) } }
    }
}

/// Pushes frames into a CoreMediaIO device's sink stream, the way OBS feeds
/// its own virtual camera. Frames are scaled (aspect-fit, black bars) to the
/// sink's declared format.
public final class CMIOSinkClient: @unchecked Sendable {
    public let target: VirtualCameraTarget
    public let width: Int
    public let height: Int
    private let device: CMIOObjectID
    private let stream: CMIOStreamID
    private var queue: CMSimpleQueue?
    private var pool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    private var format: CMVideoFormatDescription?
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.jcantor.mirada", category: "virtualcam")
    public private(set) var sent = 0
    public private(set) var dropped = 0

    public init(target: VirtualCameraTarget) throws {
        guard let dev = CMIO.devices().first(where: { $0.name == target.deviceName }) else {
            throw MiradaError.virtualCameraUnavailable("\(target.deviceName) is not installed")
        }
        guard let sink = dev.streams.first(where: \.isSink) else {
            throw MiradaError.virtualCameraUnavailable("\(target.deviceName) has no input stream")
        }
        self.target = target
        device = dev.id
        stream = sink.id
        let dims = CMIO.formatDescription(sink.id).map(CMVideoFormatDescriptionGetDimensions) ?? CMVideoDimensions(width: 1280, height: 720)
        width = Int(dims.width)
        height = Int(dims.height)
    }

    public func start() throws {
        try lock.withLock {
            guard queue == nil else { return }
            var q: Unmanaged<CMSimpleQueue>?
            let status = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &q)
            guard status == noErr, let q else { throw MiradaError.virtualCameraUnavailable("can't open \(target.deviceName) (\(status))") }
            queue = q.takeRetainedValue()
            let started = CMIODeviceStartStream(device, stream)
            guard started == noErr else {
                queue = nil
                throw MiradaError.virtualCameraUnavailable("can't start \(target.deviceName) (\(started))")
            }
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            if let transfer {
                VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            }
            log.info("publishing to \(self.target.deviceName, privacy: .public) at \(self.width)x\(self.height)")
        }
    }

    public func stop() {
        lock.withLock {
            guard queue != nil else { return }
            CMIODeviceStopStream(device, stream)
            queue = nil
        }
    }

    deinit { stop() }

    /// Sends one frame. Drops it (rather than blocking) when the sink is full.
    public func send(_ buffer: CVPixelBuffer) {
        lock.withLock {
            guard let queue else { return }
            guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
                dropped += 1
                return
            }
            guard let out = fit(buffer), let sample = sampleBuffer(out) else {
                dropped += 1
                return
            }
            let status = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
            if status == noErr { sent += 1 } else { Unmanaged.passUnretained(sample).release(); dropped += 1 }
        }
    }

    private func fit(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
           CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA { return buffer }
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out, let transfer else { return nil }
        return VTPixelTransferSessionTransferImage(transfer, from: buffer, to: out) == noErr ? out : nil
    }

    private func sampleBuffer(_ pb: CVPixelBuffer) -> CMSampleBuffer? {
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: pb) {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
}

/// Publishes corrected frames to the best available virtual camera.
public final class VirtualCameraSink: FrameSink, @unchecked Sendable {
    public let client: CMIOSinkClient

    /// Opens `preferred`, or the best available target.
    public init(preferred: VirtualCameraTarget? = nil) throws {
        let candidates = preferred.map { [$0] } ?? VirtualCameraTarget.available()
        guard let target = candidates.first else {
            throw MiradaError.virtualCameraUnavailable("no virtual camera installed (Mirada Camera needs a paid developer team; OBS Virtual Camera works without one)")
        }
        client = try CMIOSinkClient(target: target)
        try client.start()
    }

    public var target: VirtualCameraTarget { client.target }

    public func consume(_ frame: ProcessedFrame) async throws {
        client.send(frame.output.pixelBuffer)
    }

    public func finish() async throws {
        client.stop()
    }
}
