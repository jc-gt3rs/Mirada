import ArgumentParser
import Foundation
import MiradaKit

struct CalibrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Set where your camera is, your eye spacing and the camera's focal length.",
        discussion: """
        With no options on a terminal it asks step by step. Distances are centimetres from \
        the centre of the screen you look at; +x is right, +y is down, so a camera above the \
        screen has a negative y. --measure sits you at --distance and estimates the focal \
        length from your eye spacing over 3 seconds of camera.
        """
    )

    @Option(name: .long, help: "Camera above the screen centre, cm.") var above: Double?
    @Option(name: .long, help: "Camera right of the screen centre, cm.") var right: Double?
    @Option(name: .long, help: "Camera depth relative to the screen, cm (negative = behind).") var depth: Double?
    @Option(name: .long, help: "Your interpupillary distance, cm (adult average 6.3).") var ipd: Double?
    @Option(name: .long, help: "Focal length in pixels, if you know it.") var focal: Double?
    @Flag(name: .long, help: "Measure the focal length with the camera.") var measure = false
    @Option(name: .long, help: "Your eyes' distance from the camera for --measure, cm (tape, ruler, or hand spans x ~20 cm).") var distance: Double = 55
    @Option(name: .long, help: "Camera unique ID or name.") var camera: String?
    @Flag(name: .long, help: "Reset to defaults first.") var reset = false
    @Flag(name: .long, help: "Write the result as JSON to stdout.") var json = false

    func validate() throws {
        if let ipd, !(4.5...8).contains(ipd) { throw ValidationError("--ipd should be between 4.5 and 8 cm") }
        if let focal, !(100...5000).contains(focal) { throw ValidationError("--focal should be between 100 and 5000 px") }
        if !(20...200).contains(distance) { throw ValidationError("--distance should be between 20 and 200 cm") }
    }

    func run() async throws {
        try await CLI.run {
            var settings = reset ? MiradaSettings.firstRunDefaults() : MiradaSettings.load()
            let interactive = isatty(STDIN_FILENO) != 0 && !json
                && above == nil && right == nil && depth == nil && ipd == nil && focal == nil && !measure
            var doMeasure = measure
            var dist = distance

            if interactive {
                print(":mirada: calibrate // press return to keep a value\n")
                settings.camera.offsetY = -(ask("#1 camera above the screen centre (cm)", -settings.camera.offsetY))
                settings.camera.offsetX = ask("#2 camera right of the screen centre (cm)", settings.camera.offsetX)
                settings.camera.ipd = ask("#3 your pupil distance (cm)", settings.camera.ipd)
                doMeasure = askYes("#4 measure the focal length now? sit facing the screen")
                if doMeasure { dist = ask("   distance from the camera to your eyes, cm (no ruler? hand spans x 20)", dist) }
            } else {
                if let above { settings.camera.offsetY = -above }
                if let right { settings.camera.offsetX = right }
                if let depth { settings.camera.offsetZ = depth }
                if let ipd { settings.camera.ipd = ipd }
                if let focal {
                    settings.camera.focalLength = focal
                    settings.camera.focalCalibrated = true
                }
            }

            if doMeasure {
                if !json { CLI.warn("measuring: look at the screen for 3 seconds") }
                let iod = try await Self.medianInterocular(cameraID: camera ?? settings.cameraID, seconds: 3)
                settings.camera.focalLength = iod * dist / settings.camera.ipd
                settings.camera.focalCalibrated = true
            }
            try settings.save()

            if json {
                CLI.printJSON(settings.camera)
            } else {
                let c = settings.camera
                print(String(format: "saved // camera %.1f cm above, %.1f cm right, depth %.1f cm · ipd %.1f cm · f %.0f px",
                             -c.offsetY, c.offsetX, c.offsetZ, c.ipd, c.focalLength))
            }
        }
    }

    /// Median interocular distance (px) over frontal, open-eyed frames.
    static func medianInterocular(cameraID: String?, seconds: Double) async throws -> Double {
        let source = CameraSource(config: CameraSource.Config(deviceID: cameraID))
        let tracker = FaceTracker()
        var gate = FaceGate()
        var samples: [Double] = []
        let clock = Stopwatch()
        for try await frame in source.frames() {
            if let face = try tracker.detect(frame), gate.classify(face) == .tracking {
                samples.append(face.interocularPixels)
            }
            if clock.ms > seconds * 1000 { break }
        }
        source.stop()
        guard samples.count >= 10 else {
            throw MiradaError.cameraUnavailable("couldn't see your face clearly (\(samples.count) good frames); face the screen and try again")
        }
        return samples.sorted()[samples.count / 2]
    }

    private func ask(_ prompt: String, _ current: Double) -> Double {
        print(String(format: "%@ [%.1f]: ", prompt, current), terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty, let v = Double(line) else { return current }
        return v
    }

    private func askYes(_ prompt: String) -> Bool {
        print("\(prompt) [y/N]: ", terminator: "")
        return readLine()?.lowercased().hasPrefix("y") == true
    }
}
