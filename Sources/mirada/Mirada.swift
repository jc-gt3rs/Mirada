import ArgumentParser
import Foundation
import MiradaKit

@main
struct Mirada: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mirada",
        abstract: "Look at the camera. On-device gaze correction for live video and files.",
        version: "0.1.0",
        subcommands: [RunCommand.self, ProcessCommand.self, DevicesCommand.self, DoctorCommand.self, CalibrateCommand.self, DebugCommand.self]
    )
}

enum CLI {
    static let stderr = FileHandle.standardError

    static func warn(_ message: String) {
        stderr.write(Data(("mirada: " + message + "\n").utf8))
    }

    /// Runs `body`, turning `MiradaError` into a stderr message and a sysexits code.
    static func run(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as MiradaError {
            warn(error.localizedDescription)
            throw ExitCode(error.exitCode)
        }
    }

    /// Calls `handler` on Ctrl-C instead of dying, so work can clean up.
    static func onInterrupt(_ handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }

    static func printJSON(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(value), let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }
}
