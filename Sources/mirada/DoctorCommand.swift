import ArgumentParser
@preconcurrency import AVFoundation
import Foundation
import Metal
import MiradaKit

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check that this Mac can run Mirada, and say what to fix."
    )

    @Flag(name: .long, help: "Write the checks as JSON to stdout.") var json = false

    enum Level: String, Codable { case ok, warn, fail }

    struct Check: Codable {
        var name: String
        var level: Level
        var detail: String
    }

    func run() async throws {
        var checks: [Check] = []
        func add(_ name: String, _ level: Level, _ detail: String) { checks.append(Check(name: name, level: level, detail: detail)) }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        add("macOS", v.majorVersion >= 14 ? .ok : .fail, "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\(v.majorVersion >= 14 ? "" : " (needs 14 or later)")")

        #if arch(arm64)
        add("cpu", .ok, "Apple Silicon")
        #else
        add("cpu", .fail, "Intel Macs are not supported")
        #endif

        if let gpu = MTLCreateSystemDefaultDevice() {
            add("gpu", .ok, "\(gpu.name)\(gpu.supports32BitFloatFiltering ? "" : " (half-float warp textures)")")
        } else {
            add("gpu", .fail, "no Metal device")
        }

        for backend in ModelBackend.allCases {
            do {
                let model = try GazeModel(backend: backend)
                let input = EyeInput(rgb: [Float](repeating: 0.5, count: 48 * 64 * 3), anchors: [12, 24, 24, 18, 40, 18, 52, 24, 40, 30, 24, 30])
                _ = try model.predict(left: input, right: input, angle: .zero)    // warm-up
                let sw = Stopwatch()
                let out = try model.predict(left: input, right: input, angle: GazeAngle(vertical: 10, horizontal: 0))
                let ms = sw.ms
                let finite = out.left.flow.allSatisfy(\.isFinite) && out.right.light.allSatisfy(\.isFinite)
                add("model \(backend.rawValue)", finite ? .ok : .fail, String(format: "%@, %.2f ms per frame", backend == .ane ? "fp16, Neural Engine" : "fp32, CPU", ms))
            } catch {
                add("model \(backend.rawValue)", .fail, error.localizedDescription)
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: add("camera access", .ok, "allowed")
        case .notDetermined: add("camera access", .warn, "not asked yet; `mirada run` will ask (it's granted per terminal app)")
        default: add("camera access", .fail, "denied; allow your terminal in System Settings > Privacy & Security > Camera")
        }

        let cams = CameraDevices.list()
        let physical = cams.filter { !$0.isVirtual }
        add("cameras", physical.isEmpty ? .fail : .ok, physical.isEmpty ? "no physical camera" : physical.map(\.name).joined(separator: ", "))

        let targets = VirtualCameraTarget.available()
        if targets.contains(.mirada) {
            add("virtual camera", .ok, "Mirada Camera is installed and active")
        } else if targets.contains(.obs) {
            add("virtual camera", .ok, "OBS Virtual Camera (Mirada Camera needs a paid developer team)")
        } else {
            add("virtual camera", .warn, "none; install OBS Studio and start its virtual camera once, or build with a paid team")
        }

        let s = MiradaSettings.load()
        let exists = FileManager.default.fileExists(atPath: MiradaSettings.defaultURL.path)
        add("settings", .ok, String(format: "%@ · camera %.1f cm above · f %.0f px · ipd %.1f cm · strength %d%%",
                                    exists ? MiradaSettings.defaultURL.path : "defaults (no settings file yet)",
                                    -s.camera.offsetY, s.camera.focalLength, s.camera.ipd, Int(s.strength * 100)))

        if json {
            CLI.printJSON(checks)
        } else {
            for c in checks {
                let mark = switch c.level { case .ok: "ok  "; case .warn: "warn"; case .fail: "FAIL" }
                print("\(mark)  \(c.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(c.detail)")
            }
        }
        if checks.contains(where: { $0.level == .fail }) { throw ExitCode(69) }
    }
}
