import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import MiradaKit

@Suite struct SettingsTests {
    @Test func defaultsMatchReference() {
        let s = MiradaSettings()
        #expect(s.camera.focalLength == 650)
        #expect(s.camera.ipd == 6.3)
        #expect(s.camera.offsetX == 0)
        #expect(s.camera.offsetY == -21)
        #expect(s.camera.offsetZ == -1)
    }

    @Test func roundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
        var s = MiradaSettings()
        s.strength = 0.4
        s.cameraID = "abc"
        s.camera.offsetY = -18.5
        try s.save(to: url)
        #expect(MiradaSettings.load(from: url) == s)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let data = Data(#"{"strength":0.3,"camera":{"ipd":6.0}}"#.utf8)
        let s = try JSONDecoder().decode(MiradaSettings.self, from: data)
        #expect(s.strength == 0.3)
        #expect(s.camera.ipd == 6.0)
        #expect(s.camera.focalLength == 650)
        #expect(s.enabled)
    }

    @Test func corruptFileGivesDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("not json".utf8).write(to: url)
        #expect(MiradaSettings.load(from: url) == MiradaSettings.firstRunDefaults())
    }
}

@Suite struct StatsTests {
    @Test func nearestRankPercentiles() {
        let stats = StageStats()
        for v in (1...100).shuffled() { stats.record(.model, ms: Double(v)) }
        let s = stats.summary()[.model]!
        #expect(s.p50 == 50)
        #expect(s.p95 == 95)
        #expect(s.count == 100)
    }

    @Test func keepsOnlyRecentSamples() {
        let stats = StageStats(capacity: 10)
        for v in 1...20 { stats.record(.total, ms: Double(v)) }
        let s = stats.summary()[.total]!
        #expect(s.count == 10)
        #expect(s.p50 == 15)
    }
}

@Suite struct ExitCodeTests {
    @Test func sysexitsMapping() {
        let url = URL(fileURLWithPath: "/x")
        #expect(MiradaError.invalidArgument("x").exitCode == 64)
        #expect(MiradaError.inputUnreadable(url, "x").exitCode == 65)
        #expect(MiradaError.inputMissing(url).exitCode == 66)
        #expect(MiradaError.cameraUnavailable("x").exitCode == 69)
        #expect(MiradaError.modelMissing("x").exitCode == 69)
        #expect(MiradaError.virtualCameraUnavailable("x").exitCode == 69)
        #expect(MiradaError.internalError("x").exitCode == 70)
        #expect(MiradaError.outputUnwritable(url, "x").exitCode == 73)
        #expect(MiradaError.cameraPermissionDenied.exitCode == 77)
    }
}

@Suite struct UprightMappingTests {
    @Test func identityForUp() {
        let m = UprightMapping(bufferWidth: 1920, bufferHeight: 1080, orientation: .up)
        #expect(m.bufferPoint(CGPoint(x: 10, y: 20)) == CGPoint(x: 10, y: 20))
        #expect(m.uprightWidth == 1920)
    }

    @Test func portraitPhoneVideo() {
        // Stored landscape 1920x1080, displayed rotated 90° clockwise as 1080x1920.
        let m = UprightMapping(bufferWidth: 1920, bufferHeight: 1080, orientation: .right)
        #expect(m.uprightWidth == 1080)
        #expect(m.uprightHeight == 1920)
        // Upright top-left corner is the stored bottom-left corner.
        #expect(m.bufferPoint(CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 1080))
        // Upright top-right corner is the stored top-left corner.
        #expect(m.bufferPoint(CGPoint(x: 1080, y: 0)) == CGPoint(x: 0, y: 0))
    }

    @Test func allOrientationsMapCornersToCorners() {
        let orientations: [CGImagePropertyOrientation] = [.up, .upMirrored, .down, .downMirrored, .left, .leftMirrored, .right, .rightMirrored]
        for o in orientations {
            let m = UprightMapping(bufferWidth: 40, bufferHeight: 30, orientation: o)
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: m.uprightWidth, y: 0), CGPoint(x: 0, y: m.uprightHeight), CGPoint(x: m.uprightWidth, y: m.uprightHeight)]
            let mapped = Set(corners.map { m.bufferPoint($0) }.map { "\($0.x),\($0.y)" })
            #expect(mapped == ["0.0,0.0", "40.0,0.0", "0.0,30.0", "40.0,30.0"], Comment(rawValue: "orientation \(o.rawValue)"))
        }
    }
}
