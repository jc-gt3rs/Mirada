import AppKit
import MiradaKit
import os

/// `open -a Mirada.app --args --self-test-virtual-camera` runs the
/// virtual-camera loopback with the app's own camera permission, logs one JSON
/// line per target (subsystem com.jcantor.mirada, category selftest), and quits.
enum SelfTest {
    struct Outcome: Codable {
        var target: String
        var result: VirtualCameraLoopback.Result?
        var error: String?
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--self-test-virtual-camera") else { return }
        let log = Logger(subsystem: "com.jcantor.mirada", category: "selftest")
        Task.detached {
            var outcomes: [Outcome] = []
            for target in VirtualCameraTarget.available() {
                do {
                    outcomes.append(Outcome(target: target.rawValue, result: try await VirtualCameraLoopback.run(target)))
                } catch {
                    outcomes.append(Outcome(target: target.rawValue, error: error.localizedDescription))
                }
            }
            if outcomes.isEmpty { outcomes.append(Outcome(target: "none", error: "no virtual camera installed")) }
            for o in outcomes {
                let line = (try? String(data: JSONEncoder().encode(o), encoding: .utf8)) ?? "?"
                print(line)
                log.info("self-test: \(line, privacy: .public)")
            }
            exit(outcomes.contains { $0.result?.ok == true } ? 0 : 1)
        }
    }
}
