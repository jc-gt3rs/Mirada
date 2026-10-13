import CoreMedia
import Foundation

/// A video file played back like a camera: frames arrive at their real-time
/// pace, the newest wins when the consumer is slow, and it can loop forever
/// with monotonically increasing timestamps. Used for `mirada run --simulate`
/// and soak tests.
public final class PacedFileSource: FrameSource, @unchecked Sendable {
    public let url: URL
    public let loop: Bool

    public init(url: URL, loop: Bool = true) {
        self.url = url
        self.loop = loop
    }

    public func frames() -> AsyncThrowingStream<Frame, Error> {
        let url = url, loop = loop
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let clock = ContinuousClock()
                    let start = clock.now
                    var offset = 0.0
                    repeat {
                        let source = try await FileSource(url: url)
                        var last = 0.0
                        for try await frame in source.frames() {
                            try Task.checkCancellation()
                            let t = offset + frame.time.seconds
                            let due = start + .milliseconds(Int64(t * 1000))
                            if due > clock.now { try await Task.sleep(until: due, clock: clock) }
                            continuation.yield(Frame(pixelBuffer: frame.pixelBuffer, time: CMTime(seconds: t, preferredTimescale: 600), orientation: frame.orientation))
                            last = frame.time.seconds
                        }
                        offset += last + 1.0 / 30
                    } while loop && !Task.isCancelled
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Resident memory of this process, in megabytes.
public enum ProcessMemory {
    public static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
