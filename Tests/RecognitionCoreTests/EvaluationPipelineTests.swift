import AVFoundation
import FaceModel
@testable import FaceUnlock
import RecognitionCore
import Testing
import Vision

struct EvaluationPipelineTests {
    private var face: VNFaceObservation { VNFaceObservation(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)) }
    private func image() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        return try #require(buffer)
    }
    private func profile() throws -> EnrollmentProfile {
        var unit = [Float](repeating: 0, count: 128); unit[0] = 1
        return try EnrollmentProfile(model: .sface, embedding: unit)
    }

    @Test func evaluationCollectsExactlyFifteenEvenWhenEveryFramePasses() throws {
        let model = EvaluationTestModel()
        let pipeline = RecognitionPipeline(mode: .evaluate, profile: try profile(), model: model)
        let buffer = try image()
        for i in 0..<15 {
            let result = pipeline.process(buffer, faces: [face], quality: 0.8, timestamp: Double(i), frameTimestamp: Double(i+100))
            #expect(result.evaluation?.validCount == i+1)
            #expect(result.complete == (i == 14))
            #expect(result.candidate == nil && !result.text.hasPrefix("Match") && !result.text.hasPrefix("Inconclusive"))
        }
        let terminal = pipeline.process(buffer, faces: [face], quality: 0.8, timestamp: 15, frameTimestamp: 115)
        #expect(terminal.evaluation?.validCount == 15 && terminal.evaluation?.phase == .completed && model.calls == 15)
        #expect(terminal.evaluation?.analyze(threshold: 0.7)?.threeConsecutivePasses == true)
    }

    @Test func qualityMultipleFacesAndRepeatedFramesDoNotInvokeInference() throws {
        let model = EvaluationTestModel()
        let pipeline = RecognitionPipeline(mode: .evaluate, profile: try profile(), model: model)
        let buffer = try image()
        _ = pipeline.process(buffer, faces: [face], quality: 0.8, timestamp: 0, frameTimestamp: 10)
        _ = pipeline.process(buffer, faces: [face], quality: 0.8, timestamp: 1, frameTimestamp: 10)
        _ = pipeline.process(buffer, faces: [face], quality: 0.1, timestamp: 2, frameTimestamp: 11)
        let multi = pipeline.process(buffer, faces: [face,face], quality: 0.8, timestamp: 3, frameTimestamp: 12)
        #expect(multi.evaluation?.validCount == 1 && multi.evaluation?.rejectedCount == 3)
        #expect(multi.evaluation?.currentScore == nil && model.calls == 1)
        let rejected = pipeline.rejectEvaluationFrame("Invalid capture timestamp", at: 4)
        #expect(rejected.evaluation?.rejectedCount == 4)
    }

    @Test func missingCorruptProfileAndInvalidOutputFailClosed() throws {
        let buffer = try image()
        let model = EvaluationTestModel()
        let missing = RecognitionPipeline(mode: .evaluate, profile: nil, model: model)
        let result = missing.process(buffer, faces: [face], quality: 0.8, timestamp: 0)
        #expect(result.complete && result.evaluation?.phase == .failed && model.calls == 0)
        let encoded = try JSONEncoder().encode(profile())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String:Any])
        object["embedding"] = [Float](repeating: 0, count: 128)
        let corrupted = try JSONDecoder().decode(EnrollmentProfile.self, from: JSONSerialization.data(withJSONObject: object))
        let corrupt = RecognitionPipeline(mode: .evaluate, profile: corrupted, model: model)
        #expect(corrupt.process(buffer, faces: [face], quality: 0.8, timestamp: 0).evaluation?.phase == .failed)
        #expect(model.calls == 0)
        model.invalid = true
        let invalid = RecognitionPipeline(mode: .evaluate, profile: try profile(), model: model)
        let failure = invalid.process(buffer, faces: [face], quality: 0.8, timestamp: 0)
        #expect(failure.complete && failure.evaluation?.phase == .failed && failure.evaluation?.validCount == 0)
        #expect(failure.evaluation?.rejectedCount == 1)
    }

    @Test func timeoutAndCaptureFailurePreserveOnlyPartialResults() throws {
        let pipeline = RecognitionPipeline(mode: .evaluate, profile: try profile(), model: EvaluationTestModel())
        pipeline.beginEvaluation(at: 0)
        let buffer = try image()
        _ = pipeline.process(buffer, faces: [face], quality: 0.8, timestamp: 1)
        let timedOut = pipeline.process(buffer, faces: [face], quality: 0.8, timestamp: 45)
        #expect(timedOut.complete && timedOut.evaluation?.phase == .timedOut && timedOut.evaluation?.validCount == 1)
        #expect(timedOut.evaluation?.currentScore == nil)
        let failure = RecognitionPipeline(mode: .evaluate, profile: try profile(), model: EvaluationTestModel())
        _ = failure.process(buffer, faces: [face], quality: 0.8, timestamp: 0)
        #expect(failure.finishEvaluation(.failed, at: 1)?.phase == .failed)
        #expect(failure.evaluationSnapshot(at: 10)?.validCount == 1)
    }

    @Test func normalVerificationRemainsInconclusiveAtThreeAndEvaluationRetryIsFresh() throws {
        let buffer = try image(), reference = try profile()
        let verify = RecognitionPipeline(mode: .verify, profile: reference, model: EvaluationTestModel())
        var result = RecognitionFrameResult(text: "")
        for i in 0..<3 { result = verify.process(buffer, faces: [face], quality: 0.8, timestamp: Double(i)) }
        #expect(result.complete && result.text.hasPrefix("Inconclusive") && result.evaluation == nil)
        let first = RecognitionPipeline(mode: .evaluate, profile: reference, model: EvaluationTestModel())
        _ = first.process(buffer, faces: [face], quality: 0.8, timestamp: 0)
        let retry = RecognitionPipeline(mode: .evaluate, profile: reference, model: EvaluationTestModel())
        let clean = retry.process(buffer, faces: [face], quality: 0.8, timestamp: 1)
        #expect(clean.evaluation?.validCount == 1 && clean.evaluation?.rejectedCount == 0 && !clean.complete)
        #expect(VerificationPolicy.sface.threshold == 0.363)
    }

    @Test @MainActor func cancellationClearsEvaluationAndStopsAnIdleSession() {
        let camera = CameraController()
        camera.report("Cancelled evaluation")
        camera.stop(wait: true)
        #expect(camera.evaluation == nil && !camera.session.isRunning && !camera.completed)
        #expect(RecognitionMode.evaluate.timeout == 45 && RecognitionMode.verify.timeout == 20 && RecognitionMode.enroll.timeout == 90)
    }
}

private final class EvaluationTestModel: FaceEmbeddingModel {
    private(set) var calls = 0
    var invalid = false
    func embedding(from buffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float] {
        calls += 1
        var unit = [Float](repeating: 0, count: 128); unit[0] = invalid ? .nan : 1
        return unit
    }
}
