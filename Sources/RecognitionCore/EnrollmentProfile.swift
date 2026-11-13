import Foundation

public struct ModelIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let weightsSHA256: String
    public let pipelineVersion: Int
    public let dimensions: Int

    public static let sface = ModelIdentity(
        name: "SFace-2021dec-CoreML-fp32",
        weightsSHA256: "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
        pipelineVersion: 1, dimensions: 128
    )
}

public struct EnrollmentProfile: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let model: ModelIdentity
    public let createdAt: Date
    public let embedding: [Float]

    public init(model: ModelIdentity, embedding: [Float], createdAt: Date = Date()) throws {
        guard embedding.count == model.dimensions else { throw RecognitionError.invalidEmbedding }
        schemaVersion = 1
        self.model = model
        self.embedding = try Embedding.normalize(embedding)
        self.createdAt = createdAt
    }

    public func validate(for expected: ModelIdentity) throws {
        guard schemaVersion == 1, model == expected else { throw RecognitionError.incompatibleProfile }
        guard embedding.count == expected.dimensions else { throw RecognitionError.corruptProfile }
        let normalized = try Embedding.normalize(embedding)
        guard zip(normalized, embedding).allSatisfy({ abs($0 - $1) < 0.001 }) else {
            throw RecognitionError.corruptProfile
        }
    }
}

public protocol EnrollmentStore: Sendable {
    func load() throws -> EnrollmentProfile?
    /// Replace the single record atomically; failure must leave the previous record intact.
    func save(_ profile: EnrollmentProfile) throws
    func delete() throws
}

public struct EnrollmentTransaction {
    public static let requiredSamples = 6
    public private(set) var samples: [[Float]] = []
    public init() {}
    public mutating func append(_ vector: [Float], model: ModelIdentity = .sface) throws {
        guard samples.count < Self.requiredSamples, vector.count == model.dimensions else {
            throw RecognitionError.invalidEmbedding
        }
        let unit = try Embedding.normalize(vector)
        // Reject identity switching during replacement, rather than average two people.
        if let first = samples.first, try Embedding.cosine(first, unit) < VerificationPolicy.sface.threshold {
            throw RecognitionError.inconsistentSamples
        }
        samples.append(unit)
    }
    public func commit(to store: EnrollmentStore, model: ModelIdentity = .sface) throws -> EnrollmentProfile {
        guard samples.count == Self.requiredSamples else { throw RecognitionError.incompleteEnrollment }
        let profile = try EnrollmentProfile(model: model, embedding: Embedding.centroid(samples))
        try store.save(profile)
        return profile
    }
}
