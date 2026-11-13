import AVFoundation
import FaceModel
@testable import FaceUnlock
import Foundation
import RecognitionCore
import Testing
import Vision

struct PipelineTests {
    private func vector(_ index: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: 128)
        vector[index] = 1
        return vector
    }
    private func buffer() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let code = CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &result)
        #expect(code == kCVReturnSuccess)
        return try #require(result)
    }
    private var face: VNFaceObservation {
        VNFaceObservation(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
    }

    @Test func realInterfaceWithDeterministicMockRequiresThreeFrames() throws {
        let model = MockFaceModel(vector: vector(0))
        let profile = try EnrollmentProfile(model: .sface, embedding: vector(0))
        let pipeline = RecognitionPipeline(mode: .verify, profile: profile, model: model)
        let image = try buffer()
        let first = pipeline.process(image, faces: [face], quality: 0.8, timestamp: 0)
        #expect(!first.complete)
        let second = pipeline.process(image, faces: [face], quality: 0.8, timestamp: 0.5)
        #expect(!second.complete)
        let third = pipeline.process(image, faces: [face], quality: 0.8, timestamp: 1)
        #expect(third.complete && third.text.hasPrefix("Match"))
        #expect(model.calls == 3)
    }

    @Test func noFaceMultipleFacesAndLowQualityNeverInvokeModel() throws {
        let model = MockFaceModel(vector: vector(0))
        let profile = try EnrollmentProfile(model: .sface, embedding: vector(0))
        let pipeline = RecognitionPipeline(mode: .verify, profile: profile, model: model)
        let image = try buffer()
        #expect(!pipeline.process(image, faces: [], quality: 0.8, timestamp: 0).complete)
        #expect(!pipeline.process(image, faces: [face, face], quality: 0.8, timestamp: 1).complete)
        #expect(!pipeline.process(image, faces: [face], quality: 0.1, timestamp: 2).complete)
        #expect(model.calls == 0)
    }

    @Test func wrongIdentityTimesOutAndModelFailureNeverMatches() throws {
        let image = try buffer()
        let profile = try EnrollmentProfile(model: .sface, embedding: vector(0))
        let pipeline = RecognitionPipeline(mode: .verify, profile: profile, model: MockFaceModel(vector: vector(1)))
        var result = RecognitionFrameResult(text: "")
        for i in 0..<15 {
            result = pipeline.process(image, faces: [face], quality: 0.8, timestamp: Double(i) * 0.5)
        }
        #expect(result.complete && result.text == "No match")
        let failingModel = MockFaceModel(vector: vector(0), error: RecognitionError.modelUnavailable)
        let failing = RecognitionPipeline(mode: .verify, profile: profile, model: failingModel)
        let error = failing.process(image, faces: [face], quality: 0.8, timestamp: 0)
        #expect(error.complete && error.text.hasPrefix("Error:"))
        #expect(error.candidate == nil)
    }

    @Test func noEnrollmentAndWallClockTimeoutFailClosed() throws {
        let image = try buffer()
        let pipeline = RecognitionPipeline(mode: .verify, profile: nil, model: MockFaceModel(vector: vector(0)))
        let result = pipeline.process(image, faces: [face], quality: 0.8, timestamp: 0)
        #expect(result.complete && result.text.hasPrefix("Error:"))
        let waiting = RecognitionPipeline(mode: .verify, profile: nil, model: MockFaceModel(vector: vector(0)))
        _ = waiting.process(image, faces: [], quality: nil, timestamp: 0)
        #expect(waiting.process(image, faces: [], quality: nil, timestamp: 21).complete)
    }
}

// Test-only implementation of the exact production inference interface.
private final class MockFaceModel: FaceEmbeddingModel {
    let vector: [Float]
    let error: Error?
    private(set) var calls = 0
    init(vector: [Float], error: Error? = nil) { self.vector = vector; self.error = error }
    func embedding(from buffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float] {
        calls += 1
        if let error { throw error }
        return vector
    }
}

struct EnrollmentManagerTests {
    @Test @MainActor func reloadMakesStorageFailureVisibleAndRecovers() async throws {
        var unit = [Float](repeating: 0, count: 128)
        unit[0] = 1
        let profile = try EnrollmentProfile(model: .sface, embedding: unit)
        let store = ManagerStore(profile: profile)
        let manager = EnrollmentManager(store: store)
        try await waitForIdle(manager)
        #expect(manager.profile == profile && !manager.storageFailed)
        store.readError = RecognitionError.storage(-25293)
        await withCheckedContinuation { continuation in
            manager.reload { continuation.resume() }
        }
        #expect(manager.storageFailed)
        #expect(manager.profile == profile) // preserved but cannot be verified while storageFailed
        store.readError = nil
        store.profile = nil
        await withCheckedContinuation { continuation in
            manager.reload { continuation.resume() }
        }
        #expect(!manager.storageFailed && manager.profile == nil && manager.status == "Not Enrolled")
    }

    @Test @MainActor func saveFailurePreservesProfileAndDeleteUpdatesStatus() async throws {
        var first = [Float](repeating: 0, count: 128)
        first[0] = 1
        var second = [Float](repeating: 0, count: 128)
        second[1] = 1
        let old = try EnrollmentProfile(model: .sface, embedding: first)
        let candidate = try EnrollmentProfile(model: .sface, embedding: second)
        let store = ManagerStore(profile: old)
        let manager = EnrollmentManager(store: store)
        try await waitForIdle(manager)
        store.failWrites = true
        let saved: Bool = await withCheckedContinuation { continuation in
            manager.save(candidate) { continuation.resume(returning: $0) }
        }
        #expect(!saved && manager.storageFailed)
        #expect(manager.profile == old && store.profile == old)
        store.failWrites = false
        manager.delete()
        try await waitForIdle(manager)
        #expect(manager.profile == nil && store.profile == nil && !manager.storageFailed)
    }

    @MainActor private func waitForIdle(_ manager: EnrollmentManager) async throws {
        for _ in 0..<200 {
            if !manager.busy { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Enrollment manager did not complete its test storage operation")
        throw RecognitionError.storage(-1)
    }
}

// Mutated only between completed serial operations in these isolated tests.
private final class ManagerStore: EnrollmentStore, @unchecked Sendable {
    var profile: EnrollmentProfile?
    var readError: Error?
    var failWrites = false
    init(profile: EnrollmentProfile?) { self.profile = profile }
    func load() throws -> EnrollmentProfile? {
        if let readError { throw readError }
        return profile
    }
    func save(_ profile: EnrollmentProfile) throws {
        if failWrites { throw RecognitionError.storage(-1) }
        self.profile = profile
    }
    func delete() throws {
        if failWrites { throw RecognitionError.storage(-1) }
        profile = nil
    }
}
