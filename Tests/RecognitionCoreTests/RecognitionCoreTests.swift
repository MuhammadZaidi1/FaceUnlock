import Foundation
import Testing
@testable import RecognitionCore

struct RecognitionCoreTests {
    private func vector(_ index: Int = 0) -> [Float] {
        var result = [Float](repeating: 0, count: 128)
        result[index] = 1
        return result
    }

    @Test func testNormalizationAndCosine() throws {
        expectEqual(try Embedding.normalize([3, 4]), [0.6, 0.8])
        expectEqual(try Embedding.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        expectEqual(try Embedding.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        expectEqual(try Embedding.cosine([1, 0], [-1, 0]), -1, accuracy: 1e-6)
        expectEqual(try Embedding.cosine([3, 0], [20, 0]), 1, accuracy: 1e-6)
    }

    @Test func testNormalizationHandlesLargeAndSmallValues() throws {
        for value in [Float.greatestFiniteMagnitude, Float.leastNormalMagnitude] {
            let normalized = try Embedding.normalize([value, value])
            expectEqual(normalized[0], 1 / sqrt(2), accuracy: 1e-6)
        }
    }

    @Test func testInvalidEmbeddingsFailClosed() {
        for input: [Float] in [[], [0, 0], [.nan], [.infinity]] {
            expectThrows(try Embedding.normalize(input))
        }
        expectThrows(try Embedding.cosine([1], [1, 0]))
        expectThrows(try Embedding.centroid([[1, 0], [1]]))
        expectThrows(try Embedding.centroid([[1, 0], [-1, 0]]))
    }

    @Test func testCentroidNormalizesIndividualSamples() throws {
        let mean = try Embedding.centroid([[100, 0], [0, 1]])
        expectEqual(mean[0], mean[1], accuracy: 1e-6)
        expectEqual(try Embedding.cosine(mean, mean), 1, accuracy: 1e-6)
    }

    @Test func testPublishedThresholdBoundaries() {
        let policy = VerificationPolicy.sface
        expectFalse(policy.accepts(0.363.nextDown))
        expectTrue(policy.accepts(0.363))
        expectTrue(policy.accepts(0.363.nextUp))
        expectFalse(policy.accepts(.nan))
        expectFalse(policy.accepts(.infinity))
        expectFalse(policy.accepts(1.1))
    }

    @Test func testRequiresDistinctConsecutiveFrames() {
        var verifier = VerificationAccumulator()
        expectEqual(verifier.observe(score: 1, timestamp: 0), .checking)
        expectEqual(verifier.observe(score: 1, timestamp: 0), .checking)
        expectEqual(verifier.observe(score: 1, timestamp: 0.1), .checking)
        expectEqual(verifier.observe(score: 1, timestamp: 0.5), .checking)
        expectEqual(verifier.observe(score: 0, timestamp: 1), .checking)
        expectEqual(verifier.observe(score: 1, timestamp: 1.5), .checking)
        expectEqual(verifier.observe(score: 1, timestamp: 2), .checking)
        expectEqual(verifier.observe(score: 1, timestamp: 2.5), .match)
        expectEqual(verifier.observe(score: 0, timestamp: 3), .match)
    }

    @Test func testPoorQualityResetsStreakAndAttemptEventuallyEnds() {
        var verifier = VerificationAccumulator(policy: VerificationPolicy(threshold: 0.363, maximumSamples: 3))
        expectEqual(verifier.observe(score: 1, timestamp: 0), .checking)
        verifier.resetStreak()
        expectEqual(verifier.observe(score: 1, timestamp: 1), .checking)
        expectEqual(verifier.observe(score: 1, timestamp: 2), .noMatch)
    }

    @Test func testCancellationAndIncompleteReplacementLeavePreviousRecord() throws {
        let old = try EnrollmentProfile(model: .sface, embedding: vector())
        let store = MemoryStore(old)
        var transaction = EnrollmentTransaction()
        try transaction.append(vector(1))
        expectThrows(try transaction.commit(to: store))
        expectEqual(store.profile, old)
        transaction = EnrollmentTransaction() // cancellation discards in-memory samples
        expectTrue(transaction.samples.isEmpty)
        expectEqual(store.profile, old)
    }

    @Test func testAtomicReplacementAndFailurePreserveOldEnrollment() throws {
        let old = try EnrollmentProfile(model: .sface, embedding: vector())
        let store = MemoryStore(old)
        var transaction = EnrollmentTransaction()
        // Deterministic synthetic embeddings exist only in this test target.
        let model = MockEmbeddingModel(value: vector(1))
        for _ in 0..<6 { try transaction.append(model.embedding()) }
        store.failWrites = true
        expectThrows(try transaction.commit(to: store))
        expectEqual(store.profile, old)
        store.failWrites = false
        let replacement = try transaction.commit(to: store)
        expectEqual(store.profile, replacement)
        expectNotEqual(store.profile?.embedding, old.embedding)
        expectThrows(try transaction.append(vector(1)))
    }

    @Test func testInconsistentIdentitySamplesAreRejected() throws {
        var transaction = EnrollmentTransaction()
        try transaction.append(vector())
        expectThrows(try transaction.append(vector(1)))
        expectEqual(transaction.samples.count, 1)
    }

    @Test func testDeletionAndDeletionFailure() throws {
        let old = try EnrollmentProfile(model: .sface, embedding: vector())
        let store = MemoryStore(old)
        store.failWrites = true
        expectThrows(try store.delete())
        expectEqual(store.profile, old)
        store.failWrites = false
        try store.delete()
        expectNil(try store.load())
        try store.delete()
    }

    @Test func testCorruptionAndMigrationFailClosed() throws {
        let profile = try EnrollmentProfile(model: .sface, embedding: vector())
        try profile.validate(for: .sface)
        let encoded = try JSONEncoder().encode(profile)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 2
        let changed = try JSONDecoder().decode(EnrollmentProfile.self, from: JSONSerialization.data(withJSONObject: object))
        expectThrows(try changed.validate(for: .sface))
        object["schemaVersion"] = 1
        object["embedding"] = [0, 0]
        let corrupt = try JSONDecoder().decode(EnrollmentProfile.self, from: JSONSerialization.data(withJSONObject: object))
        expectThrows(try corrupt.validate(for: .sface))
        expectThrows(try JSONDecoder().decode(EnrollmentProfile.self, from: Data("not-json".utf8)))
    }

    @Test func testAttemptLimitsPersistAcrossWindowEquivalentRetries() {
        var limiter = AttemptLimiter()
        expectTrue(limiter.begin(at: 0))
        limiter.finish(at: 1)
        expectFalse(limiter.begin(at: 5))
        expectTrue(limiter.begin(at: 6))
        expectTrue(limiter.begin(at: 12))
        expectFalse(limiter.begin(at: 18))
        expectTrue(limiter.begin(at: 61))
    }
}

private protocol TestEmbeddingModel { func embedding() throws -> [Float] }
private struct MockEmbeddingModel: TestEmbeddingModel {
    let value: [Float]
    func embedding() throws -> [Float] { value }
}

private final class MemoryStore: EnrollmentStore, @unchecked Sendable {
    var profile: EnrollmentProfile?
    var failWrites = false
    init(_ profile: EnrollmentProfile?) { self.profile = profile }
    func load() throws -> EnrollmentProfile? { profile }
    func save(_ profile: EnrollmentProfile) throws {
        if failWrites { throw RecognitionError.storage(-1) }
        self.profile = profile
    }
    func delete() throws {
        if failWrites { throw RecognitionError.storage(-1) }
        profile = nil
    }
}

// Small assertion helpers retain throwing-expression support and Swift Testing reporting.
private func expectEqual<T: Equatable>(_ value: @autoclosure () throws -> T, _ expected: T) {
    do { #expect(try value() == expected) } catch { Issue.record(error) }
}
private func expectNotEqual<T: Equatable>(_ value: @autoclosure () throws -> T, _ expected: T) {
    do { #expect(try value() != expected) } catch { Issue.record(error) }
}
private func expectEqual<T: BinaryFloatingPoint>(_ value: @autoclosure () throws -> T, _ expected: T, accuracy: T) {
    do { #expect(abs(try value() - expected) <= accuracy) } catch { Issue.record(error) }
}
private func expectThrows<T>(_ expression: @autoclosure () throws -> T) {
    #expect(throws: (any Error).self) { _ = try expression() }
}
private func expectTrue(_ value: Bool) { #expect(value) }
private func expectFalse(_ value: Bool) { #expect(!value) }
private func expectNil<T>(_ value: @autoclosure () throws -> T?) {
    do { #expect(try value() == nil) } catch { Issue.record(error) }
}
