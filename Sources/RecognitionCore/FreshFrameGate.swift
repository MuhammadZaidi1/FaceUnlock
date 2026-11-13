import Foundation

/// Scalar timestamps only. A CVPixelBuffer may be reused by AVFoundation; freshness
/// follows its capture presentation timestamp, never object identity or an embedding hash.
public struct FreshFrameGate {
    private var lastCapture = -Double.infinity
    public init() {}
    public mutating func accept(_ timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp > lastCapture else { return false }
        lastCapture = timestamp
        return true
    }
}
