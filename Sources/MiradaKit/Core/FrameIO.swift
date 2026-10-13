/// Produces frames. Camera sources keep only the newest frame when the
/// consumer is slow; file sources produce on demand and never drop.
public protocol FrameSource: Sendable {
    func frames() -> AsyncThrowingStream<Frame, Error>
}

/// Consumes processed frames: preview, virtual camera, file writer.
public protocol FrameSink: AnyObject, Sendable {
    func consume(_ frame: ProcessedFrame) async throws
    func finish() async throws
}
