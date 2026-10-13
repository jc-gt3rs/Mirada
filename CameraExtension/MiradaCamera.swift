@preconcurrency import CoreMedia
@preconcurrency import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os

let cameraWidth: Int32 = 1280
let cameraHeight: Int32 = 720
let frameRate: Int32 = 30
private let log = Logger(subsystem: "com.jcantor.mirada.camera", category: "extension")

// MARK: provider

final class MiradaProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: MiradaDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = MiradaDeviceSource(localizedName: "Mirada Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Mirada Camera: can't add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Mirada" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: device

/// All mutable state is touched only on `queue`.
final class MiradaDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var source: MiradaStreamSource!
    private var sink: MiradaStreamSink!
    private let queue = DispatchQueue(label: "mirada.camera.device", qos: .userInteractive)
    private var format: CMFormatDescription!
    private var placeholder: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var sourceClients = 0
    private var sinkClient: CMIOExtensionClient?
    /// Host time of the last frame that came in through the sink.
    private var lastSinkFrame: UInt64 = 0

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: UUID(uuidString: "5F1D4A3B-6C2E-4E8A-9D1B-7A3C2E9F0B11")!,
                                     legacyDeviceID: nil, source: self)
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: cameraWidth, height: cameraHeight, extensions: nil, formatDescriptionOut: &format)
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: format,
                                                     maxFrameDuration: CMTime(value: 1, timescale: frameRate),
                                                     minFrameDuration: CMTime(value: 1, timescale: frameRate),
                                                     validFrameDurations: nil)
        source = MiradaStreamSource(localizedName: "Mirada Camera", streamID: UUID(uuidString: "1C7A2B9E-3D4F-4A6B-8C2D-5E9F1A3B7C40")!,
                                    format: streamFormat, device: self)
        sink = MiradaStreamSink(localizedName: "Mirada Camera Input", streamID: UUID(uuidString: "8E2B4C6D-1A3F-4B5C-9D7E-2F4A6C8E0B12")!,
                                format: streamFormat, device: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Mirada Camera: can't add streams: \(error.localizedDescription)")
        }
        placeholder = PlaceholderCard.make(width: Int(cameraWidth), height: Int(cameraHeight))
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "Mirada Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // A video app started or stopped reading the camera.
    func startSourceStream() {
        queue.async { [self] in
            sourceClients += 1
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(frameRate), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stopSourceStream() {
        queue.async { [self] in
            sourceClients = max(0, sourceClients - 1)
            if sourceClients == 0 {
                timer?.cancel()
                timer = nil
            }
        }
    }

    /// Shows the placeholder whenever Mirada hasn't sent a frame for half a second.
    private func tick() {
        let now = mach_absolute_time()
        guard hostNanos(now) - hostNanos(lastSinkFrame) > 500_000_000, let placeholder else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: frameRate),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: placeholder, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample {
            source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
        }
    }

    // Mirada (the app or `mirada run`) started or stopped writing frames.
    func startSinkStream(client: CMIOExtensionClient) {
        queue.async { [self] in
            sinkClient = client
            consume(from: client)
        }
    }

    func stopSinkStream() {
        queue.async { [self] in sinkClient = nil }
    }

    private func consume(from client: CMIOExtensionClient) {
        sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, error in
            guard let self else { return }
            let handoff = SampleHandoff(sample: sample)
            self.queue.async {
                guard self.sinkClient === client else { return }
                if let sample = handoff.sample {
                    self.lastSinkFrame = mach_absolute_time()
                    let host = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
                    if self.sourceClients > 0 {
                        self.source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: host)
                    }
                    self.sink.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: host))
                } else if let error {
                    log.debug("sink: \(error.localizedDescription)")
                }
                self.consume(from: client)
            }
        }
    }

    private func hostNanos(_ t: UInt64) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return t * UInt64(info.numer) / UInt64(info.denom)
    }
}

// MARK: streams

final class MiradaStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: MiradaDeviceSource

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: MiradaDeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: frameRate) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { device.startSourceStream() }
    func stopStream() throws { device.stopSourceStream() }
}

final class MiradaStreamSink: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: MiradaDeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: MiradaDeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: frameRate) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 2 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client else { throw CocoaError(.featureUnsupported) }
        device.startSinkStream(client: client)
    }

    func stopStream() throws { device.stopSinkStream() }
}

/// Passes one sample buffer from CoreMediaIO's callback to the device queue;
/// nothing else touches it.
private struct SampleHandoff: @unchecked Sendable {
    let sample: CMSampleBuffer?
}
