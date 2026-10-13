import CoreGraphics

extension EyePoints {
    /// Builds the six training-order points from a closed eye contour in any
    /// starting order or direction. Corners are the farthest-apart pair; the
    /// outer one is farther from the other eye. Lid points are the contour's
    /// own interior points when a lid has exactly two, otherwise samples at
    /// 1/3 and 2/3 of the lid's arc length.
    public static func fromContour(_ contour: [CGPoint], otherEyeCenter: CGPoint) -> EyePoints? {
        let n = contour.count
        guard n >= 4 else { return nil }

        var best = (i: 0, j: 1, d: -CGFloat.infinity)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = dist(contour[i], contour[j])
                if d > best.d { best = (i, j, d) }
            }
        }
        let (ci, cj) = dist(contour[best.i], otherEyeCenter) >= dist(contour[best.j], otherEyeCenter)
            ? (best.i, best.j) : (best.j, best.i)
        let outer = contour[ci], inner = contour[cj]

        // Two lids, each walked from outer to inner.
        func walk(from a: Int, to b: Int, step: Int) -> [CGPoint] {
            var out = [contour[a]]
            var k = a
            while k != b {
                k = (k + step + n) % n
                out.append(contour[k])
            }
            return out
        }
        let arcA = walk(from: ci, to: cj, step: 1)
        let arcB = walk(from: ci, to: cj, step: -1)

        // "Up" is the corner axis normal that points toward smaller y.
        let ax = inner.x - outer.x, ay = inner.y - outer.y
        var nx = -ay, ny = ax
        if ny > 0 { nx = -nx; ny = -ny }
        let mid = CGPoint(x: (outer.x + inner.x) / 2, y: (outer.y + inner.y) / 2)
        func lift(_ arc: [CGPoint]) -> CGFloat {
            let inside = arc.dropFirst().dropLast()
            guard !inside.isEmpty else { return 0 }
            return inside.map { ($0.x - mid.x) * nx + ($0.y - mid.y) * ny }.reduce(0, +) / CGFloat(inside.count)
        }
        let (upper, lower) = lift(arcA) >= lift(arcB) ? (arcA, arcB) : (arcB, arcA)

        let (uo, ui) = thirds(upper)
        let (lo, li) = thirds(lower)
        return EyePoints(outer: outer, upperOuter: uo, upperInner: ui, inner: inner, lowerInner: li, lowerOuter: lo)
    }

    /// Points at 1/3 and 2/3 along an arc that runs outer -> inner.
    private static func thirds(_ arc: [CGPoint]) -> (CGPoint, CGPoint) {
        if arc.count == 4 { return (arc[1], arc[2]) }
        var lengths: [CGFloat] = [0]
        for k in 1..<arc.count { lengths.append(lengths[k - 1] + dist(arc[k - 1], arc[k])) }
        let total = lengths.last ?? 0
        func at(_ t: CGFloat) -> CGPoint {
            let target = total * t
            for k in 1..<arc.count where lengths[k] >= target {
                let seg = lengths[k] - lengths[k - 1]
                let f = seg > 0 ? (target - lengths[k - 1]) / seg : 0
                return CGPoint(x: arc[k - 1].x + (arc[k].x - arc[k - 1].x) * f, y: arc[k - 1].y + (arc[k].y - arc[k - 1].y) * f)
            }
            return arc.last ?? .zero
        }
        return (at(1.0 / 3), at(2.0 / 3))
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
