import CoreGraphics
import Testing
@testable import MiradaKit

/// Expected values from the reference formula in Python (float, no int cast).
@Suite struct GazeGeometryTests {
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func centredFace() {
        let e = GazeGeometry.estimate(leftCenter: CGPoint(x: 700, y: 360), rightCenter: CGPoint(x: 580, y: 360),
                                      frameSize: CGSize(width: 1280, height: 720), camera: CameraGeometry())
        #expect(close(e.angle.vertical, 31.607502246248906))
        #expect(close(e.angle.horizontal, 0.0))
        #expect(close(e.eye.z, -34.125))
        #expect(close(e.eye.y, -21.0))
    }

    @Test func smallOffCentreFace() {
        let e = GazeGeometry.estimate(leftCenter: CGPoint(x: 990, y: 150), rightCenter: CGPoint(x: 960, y: 152),
                                      frameSize: CGSize(width: 1280, height: 720), camera: CameraGeometry())
        #expect(close(e.angle.vertical, 7.493645964203765))
        #expect(close(e.angle.horizontal, -0.1723082703415173))
        #expect(close(e.eye.x, -70.19418585521244))
    }

    @Test func tiltedFaceLowerLeft() {
        let e = GazeGeometry.estimate(leftCenter: CGPoint(x: 420, y: 500), rightCenter: CGPoint(x: 300, y: 510),
                                      frameSize: CGSize(width: 1280, height: 720), camera: CameraGeometry())
        #expect(close(e.angle.vertical, 34.47010208589677))
        #expect(close(e.angle.horizontal, 0.6277162775015412))
    }

    @Test func customCamera() {
        let cam = CameraGeometry(focalLength: 800, ipd: 6.0, offsetX: 3, offsetY: -18, offsetZ: -2)
        let e = GazeGeometry.estimate(leftCenter: CGPoint(x: 1100, y: 600), rightCenter: CGPoint(x: 1000, y: 600),
                                      frameSize: CGSize(width: 1920, height: 1080), camera: cam)
        #expect(close(e.angle.vertical, 21.174140740239718))
        #expect(close(e.angle.horizontal, -3.8329775507931063))
        #expect(close(e.eye.z, -48.0))
    }

    @Test func clampsToTrainingRange() {
        let c = GazeGeometry.clamp(GazeAngle(vertical: 44, horizontal: -55))
        #expect(c == GazeAngle(vertical: 30, horizontal: -40))
    }

    @Test func macBookDefault() {
        // 14" MacBook Pro display: about 302 x 196 mm.
        let g = CameraGeometry.aboveDisplay(widthMM: 302, heightMM: 196)
        #expect(abs(g.offsetY - -10.6) < 1e-9)
    }
}

@Suite struct OneEuroTests {
    @Test func firstSamplePassesThrough() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0)
        #expect(f.filter(5, at: 0) == 5)
    }

    @Test func constantInputStaysConstant() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0.5)
        var last = 0.0
        for i in 0..<60 { last = f.filter(3, at: Double(i) / 30) }
        #expect(last == 3)
    }

    @Test func noiseIsReduced() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0)
        var rng = SystemRandomNumberGenerator()
        var rawVar = 0.0, outVar = 0.0
        for i in 0..<600 {
            let noise = Double.random(in: -1...1, using: &rng)
            let out = f.filter(noise, at: Double(i) / 30)
            if i > 30 { rawVar += noise * noise; outVar += out * out }
        }
        #expect(outVar < rawVar / 4)
    }

    @Test func fastMotionHasLessLagWithBeta() {
        func lagAfterRamp(beta: Double) -> Double {
            var f = OneEuroFilter(minCutoff: 1, beta: beta)
            var out = 0.0
            for i in 0..<15 { out = f.filter(Double(i) * 10, at: Double(i) / 30) }
            return 140 - out
        }
        #expect(lagAfterRamp(beta: 1) < lagAfterRamp(beta: 0) / 2)
    }

    @Test func resetForgetsState() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0)
        _ = f.filter(100, at: 0)
        f.reset()
        #expect(f.filter(-4, at: 1) == -4)
    }
}

@Suite struct FaceGateTests {
    static func eye(cx: Double, open: Double) -> EyePoints {
        // 30 px wide eye; lid points 4 px either side of centre horizontally.
        EyePoints(ordered: [
            CGPoint(x: cx - 15, y: 100), CGPoint(x: cx - 5, y: 100 - open / 2), CGPoint(x: cx + 5, y: 100 - open / 2),
            CGPoint(x: cx + 15, y: 100), CGPoint(x: cx + 5, y: 100 + open / 2), CGPoint(x: cx - 5, y: 100 + open / 2),
        ])
    }

    static func face(open: Double, yaw: Double = 0, iod: Double = 70) -> FaceLandmarks {
        FaceLandmarks(leftEye: eye(cx: 100 + iod, open: open), rightEye: eye(cx: 100, open: open), bounds: .zero, yaw: yaw, pitch: 0)
    }

    @Test func aspectRatio() {
        #expect(abs(FaceGate.aspectRatio(Self.eye(cx: 0, open: 9)) - 0.3) < 1e-9)
    }

    @Test func blinkWithHysteresis() {
        var g = FaceGate()
        #expect(g.classify(Self.face(open: 9)) == .tracking)     // EAR 0.30
        #expect(g.classify(Self.face(open: 4.5)) == .blinking)   // 0.15 < close
        #expect(g.classify(Self.face(open: 5.7)) == .blinking)   // 0.19: still closed (needs > 0.21)
        #expect(g.classify(Self.face(open: 7)) == .tracking)     // 0.233
    }

    @Test func lookAwayWithHysteresis() {
        var g = FaceGate()
        #expect(g.classify(Self.face(open: 9, yaw: 22)) == .tracking)
        #expect(g.classify(Self.face(open: 9, yaw: 30)) == .lookingAway)
        #expect(g.classify(Self.face(open: 9, yaw: 22)) == .lookingAway)
        #expect(g.classify(Self.face(open: 9, yaw: 15)) == .tracking)
    }

    @Test func tinyFace() {
        var g = FaceGate()
        #expect(g.classify(Self.face(open: 9, iod: 20)) == .tooSmall)
    }
}

@Suite struct GazeTrackerTests {
    /// A frontal face with both pupils shifted by `u` (fraction of eye width, + toward image right).
    static func face(u: Double, v: Double = 0, yaw: Double = 0) -> FaceLandmarks {
        func eye(_ cx: Double) -> EyePoints {
            EyePoints(ordered: [CGPoint(x: cx - 15, y: 100), CGPoint(x: cx - 5, y: 95), CGPoint(x: cx + 5, y: 95),
                                CGPoint(x: cx + 15, y: 100), CGPoint(x: cx + 5, y: 105), CGPoint(x: cx - 5, y: 105)])
        }
        let r = eye(100), l = eye(170)
        return FaceLandmarks(leftEye: l, rightEye: r, bounds: .zero, yaw: yaw, pitch: 0,
                             leftPupil: CGPoint(x: 170 + u * 30, y: 100 + v * 30), rightPupil: CGPoint(x: 100 + u * 30, y: 100 + v * 30))
    }

    @Test func steadyGazeIsZero() {
        var g = GazeTracker()
        var d = GazeAngle.zero
        for i in 0..<60 { d = g.deviation(Self.face(u: 0.03), at: Double(i) / 30)! }
        #expect(abs(d.horizontal) < 1e-9 && abs(d.vertical) < 1e-9)
    }

    @Test func lookingAsideIsMeasured() {
        var g = GazeTracker()
        for i in 0..<300 { _ = g.deviation(Self.face(u: 0), at: Double(i) / 30) }
        // Pupils 0.1 of an eye width toward the image's right: 2.5 × 0.1 rad = 14.3°
        // (after the gaze smoothing settles, well inside the 30 s baseline window).
        var d = GazeAngle.zero
        for i in 0..<60 { d = g.deviation(Self.face(u: 0.1), at: 10 + Double(i) / 30)! }
        #expect(abs(d.horizontal - 14.32) < 0.1)
        #expect(abs(d.vertical) < 1e-9)
        // Pupils up (smaller y) -> + vertical.
        var up = GazeAngle.zero
        for i in 0..<60 { up = g.deviation(Self.face(u: 0, v: -0.08), at: 12 + Double(i) / 30)! }
        #expect(up.vertical > 10)
    }

    @Test func headTurnWithCounterRotatingEyesIsNotAGazeChange() {
        var g = GazeTracker()
        for i in 0..<300 { _ = g.deviation(Self.face(u: 0, yaw: 0), at: Double(i) / 30) }
        // Head 14.3° toward image right, eyes 14.3° back: still looking at the same spot.
        var d = GazeAngle.zero
        for i in 300..<400 { d = g.deviation(Self.face(u: -0.1, yaw: 14.32), at: Double(i) / 30)! }
        #expect(abs(d.horizontal) < 1.5)
    }

    @Test func noPupilsNoEstimate() {
        var g = GazeTracker()
        var f = Self.face(u: 0)
        f.leftPupil = nil
        #expect(g.deviation(f, at: 0) == nil)
    }
}

@Suite struct GazeExtremesTests {
    @Test func cornerGazeStaysBounded() {
        var g = GazeTracker()
        g.gainH = 4
        for i in 0..<300 { _ = g.deviation(GazeTrackerTests.face(u: 0), at: Double(i) / 30) }
        var d = GazeAngle.zero
        for i in 0..<90 { d = g.deviation(GazeTrackerTests.face(u: 0.3), at: 10 + Double(i) / 30)! }
        // 4 × 0.3 rad would be 69°; capped at 45° (the arcsine used to read 90°).
        #expect(abs(d.horizontal - 45) < 1)
    }
}

@Suite struct GazeVerticalTrustTests {
    @Test func verticalIgnoredWhenLookingFarSideways() {
        var g = GazeTracker()
        g.gainH = 4
        g.gainV = 7.5
        for i in 0..<300 { _ = g.deviation(GazeTrackerTests.face(u: 0), at: Double(i) / 30) }
        var d = GazeAngle.zero
        // Far sideways (4 × 0.2 rad = 46°, capped 45) with a pupil drop that would read as −17° vertical.
        for i in 0..<90 { d = g.deviation(GazeTrackerTests.face(u: 0.2, v: 0.04), at: 10 + Double(i) / 30)! }
        #expect(abs(d.vertical) < 0.5)
        // Looking up with the eyes centred is still fully measured.
        for i in 0..<90 { d = g.deviation(GazeTrackerTests.face(u: 0, v: -0.03), at: 14 + Double(i) / 30)! }
        #expect(d.vertical > 10)
    }
}

@Suite struct GazeCalibrationTests {
    @Test func calibratedMiddleWinsOverLearning() {
        var g = GazeTracker()
        g.fixedCentre = GazeCentre(u: 0, v: 0, yaw: 0)
        // A long stretch looking aside would drag a learned middle along; a calibrated one stays.
        var d = GazeAngle.zero
        for i in 0..<900 { d = g.deviation(GazeTrackerTests.face(u: 0.1), at: Double(i) / 30)! }
        #expect(abs(d.horizontal - 14.32) < 0.2)
    }

    @Test func learnedMiddleFollowsSlowly() {
        var g = GazeTracker()
        for i in 0..<900 { _ = g.deviation(GazeTrackerTests.face(u: 0), at: Double(i) / 30) }
        // 20 s looking aside is still clearly "aside" with a 90 s window.
        var d = GazeAngle.zero
        for i in 0..<600 { d = g.deviation(GazeTrackerTests.face(u: 0.1), at: 30 + Double(i) / 30)! }
        #expect(d.horizontal > 10)
    }

    @Test func glitchReadingsAreIgnored() {
        var g = GazeTracker()
        for i in 0..<300 { _ = g.deviation(GazeTrackerTests.face(u: 0), at: Double(i) / 30) }
        let d = g.deviation(GazeTrackerTests.face(u: 0.5), at: 10)!   // pupil "in the lid"
        #expect(abs(d.horizontal) < 0.5)
    }

    @Test func captureCentreIsTheRecentMedian() {
        var g = GazeTracker()
        for i in 0..<60 { _ = g.deviation(GazeTrackerTests.face(u: 0.05), at: Double(i) / 30) }
        let c = g.captureCentre(now: 2)!
        #expect(abs(c.u - 0.05) < 0.005)
    }
}
