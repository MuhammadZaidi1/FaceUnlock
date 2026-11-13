import Foundation
import CoreGraphics

/// Geometry is in Core Image's lower-left coordinates. No reflection is permitted.
/// Five SFace canonical points are expressed here with their top-left Y inverted.
public enum FaceAlignment {
    public static let canonical = [CGPoint(x: 38.2946, y: 112 - 51.6963), CGPoint(x: 73.5318, y: 112 - 51.5014),
        CGPoint(x: 56.0252, y: 112 - 71.7366), CGPoint(x: 41.5493, y: 112 - 92.3655), CGPoint(x: 70.7299, y: 112 - 92.2041)]

    public static func imagePoint(_ point: CGPoint, boundingBox: CGRect, extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + (boundingBox.minX + point.x * boundingBox.width) * extent.width,
                y: extent.minY + (boundingBox.minY + point.y * boundingBox.height) * extent.height)
    }

    public static func transform(source: [CGPoint], extent: CGRect) throws -> (CGAffineTransform, Double) {
        guard source.count == 5, source.allSatisfy({ $0.x.isFinite && $0.y.isFinite && extent.contains($0) }),
              source[0].x < source[1].x,
              min(source[0].y, source[1].y) > source[2].y,
              source[2].y > max(source[3].y, source[4].y), source[3].x < source[4].x else {
            throw FaceQualityError(reason: "Face landmark geometry is invalid. Face the camera and retry.")
        }
        func center(_ points: [CGPoint]) -> CGPoint {
            CGPoint(x: points.map(\.x).reduce(0, +) / 5, y: points.map(\.y).reduce(0, +) / 5)
        }
        let sCenter = center(source), tCenter = center(canonical)
        var real = 0.0, imaginary = 0.0, denominator = 0.0
        for (s, t) in zip(source, canonical) {
            let x = s.x - sCenter.x, y = s.y - sCenter.y
            let u = t.x - tCenter.x, v = t.y - tCenter.y
            real += x * u + y * v; imaginary += x * v - y * u
            denominator += x * x + y * y
        }
        guard denominator.isFinite, denominator > 1 else { throw FaceQualityError(reason: "Face landmarks are degenerate. Move closer.") }
        let a = real / denominator, b = imaginary / denominator
        let transform = CGAffineTransform(a: a, b: b, c: -b, d: a,
            tx: tCenter.x - a * sCenter.x + b * sCenter.y, ty: tCenter.y - b * sCenter.x - a * sCenter.y)
        let inverse = transform.inverted()
        // Reject unsupported padding rather than embedding a partial/black crop.
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 112, y: 0), CGPoint(x: 0, y: 112), CGPoint(x: 112, y: 112)] {
            let p = corner.applying(inverse)
            guard p.x.isFinite, p.y.isFinite, extent.insetBy(dx: -0.001, dy: -0.001).contains(p) else {
                throw FaceQualityError(reason: "Aligned face would leave the camera image. Center your face and retry.")
            }
        }
        let residual = sqrt(zip(source, canonical).reduce(0.0) { total, pair in
            let p = pair.0.applying(transform)
            return total + pow(p.x - pair.1.x, 2) + pow(p.y - pair.1.y, 2)
        } / 5)
        return (transform, residual)
    }
}
