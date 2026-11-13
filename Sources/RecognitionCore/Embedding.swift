import Foundation

public enum RecognitionError: Error, Equatable, LocalizedError {
    case invalidEmbedding, incompatibleProfile, incompleteEnrollment, inconsistentSamples
    case corruptProfile, modelUnavailable, noEnrollment
    case storage(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidEmbedding: return "Invalid face embedding. No identity decision was made."
        case .incompatibleProfile: return "Enrollment uses a different model or format. Replace it to continue."
        case .incompleteEnrollment: return "Complete all face samples before saving."
        case .inconsistentSamples: return "Samples are inconsistent. Keep the same person in view."
        case .corruptProfile: return "Stored enrollment cannot be read. Delete it or replace it."
        case .modelUnavailable: return "The face model is unavailable. No identity decision was made."
        case .noEnrollment: return "No enrollment. Enroll a face first."
        case .storage(let code): return "Keychain access failed (\(code)). Enrollment was not changed."
        }
    }
}

public enum Embedding {
    public static func normalize(_ vector: [Float]) throws -> [Float] {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite),
              let scale = vector.map({ abs(Double($0)) }).max(), scale > 0 else {
            throw RecognitionError.invalidEmbedding
        }
        let norm = sqrt(vector.reduce(0.0) { $0 + pow(Double($1) / scale, 2) })
        return vector.map { Float((Double($0) / scale) / norm) }
    }

    public static func cosine(_ lhs: [Float], _ rhs: [Float]) throws -> Double {
        guard lhs.count == rhs.count else { throw RecognitionError.invalidEmbedding }
        let a = try normalize(lhs), b = try normalize(rhs)
        return max(-1, min(1, zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }))
    }

    public static func centroid(_ samples: [[Float]]) throws -> [Float] {
        guard let first = samples.first, !first.isEmpty else { throw RecognitionError.invalidEmbedding }
        var sum = [Double](repeating: 0, count: first.count)
        for sample in samples {
            guard sample.count == sum.count else { throw RecognitionError.invalidEmbedding }
            let unit = try normalize(sample)
            for i in sum.indices { sum[i] += Double(unit[i]) / Double(samples.count) }
        }
        return try normalize(sum.map(Float.init))
    }
}
