import CoreGraphics
import Foundation

/// Physical setup used by the gaze-angle math. Units follow the reference:
/// centimetres for distances, pixels for focal length. The origin is the
/// centre of the screen; +x right, +y down, −z toward the user.
public struct CameraGeometry: Codable, Sendable, Equatable {
    public var focalLength: Double = 650
    public var ipd: Double = 6.3
    public var offsetX: Double = 0
    public var offsetY: Double = -21
    public var offsetZ: Double = -1
    /// True once the focal length was measured or entered. Until then Mirada
    /// derives it from your eye spacing, assuming you sit `assumedDistance` away.
    public var focalCalibrated = false
    public static let assumedDistance = 55.0
    /// Pupil-offset gains for gaze following (see GazeTracker). Vertical is
    /// larger because the lids move with the eye and hide most of its motion.
    public var gazeGainH: Double = 4.0
    public var gazeGainV: Double = 7.5
    /// Your eyes' reading while looking at the middle of the screen (from
    /// calibration). Nil: learned automatically, more slowly and less exactly.
    public var gazeCentre: GazeCentre?

    public init() {}

    public init(focalLength: Double, ipd: Double, offsetX: Double, offsetY: Double, offsetZ: Double) {
        self.focalLength = focalLength
        self.ipd = ipd
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.offsetZ = offsetZ
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraGeometry()
        focalLength = try c.decodeIfPresent(Double.self, forKey: .focalLength) ?? d.focalLength
        ipd = try c.decodeIfPresent(Double.self, forKey: .ipd) ?? d.ipd
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? d.offsetX
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? d.offsetY
        offsetZ = try c.decodeIfPresent(Double.self, forKey: .offsetZ) ?? d.offsetZ
        focalCalibrated = try c.decodeIfPresent(Bool.self, forKey: .focalCalibrated) ?? d.focalCalibrated
        gazeGainH = try c.decodeIfPresent(Double.self, forKey: .gazeGainH) ?? d.gazeGainH
        gazeGainV = try c.decodeIfPresent(Double.self, forKey: .gazeGainV) ?? d.gazeGainV
        gazeCentre = try c.decodeIfPresent(GazeCentre.self, forKey: .gazeCentre)
    }
}

/// Settings shared by the app and the CLI.
public struct MiradaSettings: Codable, Sendable, Equatable {
    public var camera = CameraGeometry()
    /// 0 = no correction, 1 = full geometric correction.
    public var strength: Double = 0.85
    public var enabled = true
    /// `AVCaptureDevice.uniqueID`, or nil for the system default.
    public var cameraID: String?
    /// Send live output to the virtual camera (Mirada Camera or OBS Virtual Camera).
    public var publishVirtualCamera = true
    /// Draw the pipeline's decisions (face box, eye points, crops, angle,
    /// state, timings) into the output video, everywhere it goes.
    public var debugOverlay = false
    /// Estimate where you look from your pupils (instead of assuming the
    /// middle of the screen) and correct from there.
    public var followGaze = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MiradaSettings()
        camera = try c.decodeIfPresent(CameraGeometry.self, forKey: .camera) ?? d.camera
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        cameraID = try c.decodeIfPresent(String.self, forKey: .cameraID)
        publishVirtualCamera = try c.decodeIfPresent(Bool.self, forKey: .publishVirtualCamera) ?? d.publishVirtualCamera
        debugOverlay = try c.decodeIfPresent(Bool.self, forKey: .debugOverlay) ?? d.debugOverlay
        followGaze = try c.decodeIfPresent(Bool.self, forKey: .followGaze) ?? d.followGaze
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirada", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// Returns first-run defaults when the file is missing or unreadable, so
    /// a bad file never stops Mirada from starting.
    public static func load(from url: URL = defaultURL) -> MiradaSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(MiradaSettings.self, from: data)
        else { return firstRunDefaults() }
        return settings
    }

    /// Reference defaults, except that on a Mac with a built-in display the
    /// camera position comes from the panel's physical size (the reference's
    /// 21 cm suits a large desktop monitor and over-corrects on a laptop).
    public static func firstRunDefaults() -> MiradaSettings {
        var s = MiradaSettings()
        if let size = DisplayInfo.builtInSizeMM() {
            s.camera = CameraGeometry.aboveDisplay(widthMM: size.width, heightMM: size.height)
        }
        return s
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Physical size of the built-in display, if there is one.
public enum DisplayInfo {
    public static func builtInSizeMM() -> (width: Double, height: Double)? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        guard let id = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        let size = CGDisplayScreenSize(id)
        return size.width > 0 ? (Double(size.width), Double(size.height)) : nil
    }
}
