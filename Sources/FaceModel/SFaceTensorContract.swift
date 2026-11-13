import CoreML
import RecognitionCore

/// The exact converted checkpoint contract; 128 elements alone is insufficient.
public enum SFaceTensorContract {
    public static let inputShape = [1, 3, 112, 112]
    public static let outputShape = [1, 128]
    public static func normalizedOutput(_ value: MLFeatureValue?) throws -> [Float] {
        guard let array = value?.multiArrayValue,
              array.shape.map(\.intValue) == outputShape,
              array.dataType == .float32 else { throw RecognitionError.invalidEmbedding }
        return try Embedding.normalize((0..<128).map { array[$0].floatValue })
    }
    public static func validateInput(_ rgb: [Float]) throws {
        guard rgb.count == 3 * 112 * 112,
              rgb.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else {
            throw RecognitionError.invalidEmbedding
        }
    }
    /// CIContext RGBA8 bitmap rows are top-to-bottom; no additional channel scale or flip.
    public static func channelsFirstRGB(_ rgba: [UInt8]) throws -> [Float] {
        guard rgba.count == 112 * 112 * 4 else { throw RecognitionError.invalidEmbedding }
        var rgb = [Float](repeating: 0, count: 3 * 112 * 112)
        for i in 0..<(112 * 112) {
            for c in 0..<3 { rgb[c * 112 * 112 + i] = Float(rgba[i * 4 + c]) }
        }
        return rgb
    }
}
