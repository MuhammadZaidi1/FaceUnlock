import AVFoundation
import CoreML
import FaceModel
@testable import FaceUnlock
import Foundation
import RecognitionCore
import Testing
import Vision

struct FalseAcceptanceRegressionTests {
    private func unit(_ index: Int = 0) -> [Float] {
        var vector = [Float](repeating: 0, count: 128); vector[index] = 1; return vector
    }
    private func buffer() throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &image) == kCVReturnSuccess)
        return try #require(image)
    }
    private var face: VNFaceObservation { VNFaceObservation(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)) }
    private func pipeline(_ model: FaceEmbeddingModel) throws -> RecognitionPipeline {
        RecognitionPipeline(mode: .verify, profile: try EnrollmentProfile(model: .sface, embedding: unit()), model: model)
    }

    @Test func freshFrameDataIsUsedAndDifferentEmbeddingDoesNotPass() throws {
        let model = BufferReadingTestModel()
        let worker = try pipeline(model)
        let image = try buffer()
        for index in 0..<15 {
            CVPixelBufferLockBaseAddress(image, [])
            let base = try #require(CVPixelBufferGetBaseAddress(image))
            base.storeBytes(of: UInt8(index == 0 ? 0 : 1), as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(image, [])
            let result = worker.process(image, faces: [face], quality: 0.8, timestamp: Double(index), frameTimestamp: Double(index + 100))
            let d = try #require(result.recognitionDiagnostics)
            #expect(d.score == (index == 0 ? 1 : 0))
            #expect(d.passedThreshold == (index == 0))
            #expect(d.streak == (index == 0 ? 1 : 0))
            if index == 14 { #expect(result.complete && result.text == "No match") }
        }
        #expect(model.calls == 15) // same buffer object, changed frame contents
    }

    @Test func duplicateBackwardAndInvalidCaptureTimestampsNeverInvokeInference() throws {
        let model = BufferReadingTestModel()
        let worker = try pipeline(model)
        let image = try buffer()
        CVPixelBufferLockBaseAddress(image, [])
        CVPixelBufferGetBaseAddress(image)?.storeBytes(of: UInt8(0), as: UInt8.self)
        CVPixelBufferUnlockBaseAddress(image, [])
        _ = worker.process(image, faces: [face], quality: 0.8, timestamp: 0, frameTimestamp: 10)
        for (index, pts) in [10.0, 9.0, Double.nan].enumerated() {
            let result = worker.process(image, faces: [face], quality: 0.8, timestamp: Double(index + 1), frameTimestamp: pts)
            #expect(result.recognitionDiagnostics?.freshFrame == false)
            #expect(result.recognitionDiagnostics?.score == nil)
            #expect(result.recognitionDiagnostics?.streak == 0)
        }
        #expect(model.calls == 1)
        let fresh = worker.process(image, faces: [face], quality: 0.8, timestamp: 4, frameTimestamp: 11)
        #expect(fresh.recognitionDiagnostics?.streak == 1 && model.calls == 2)
    }

    @Test func qualityFailureResetsAndThreeNewPassesEndInconclusiveNotAcceptance() throws {
        let model = BufferReadingTestModel()
        let worker = try pipeline(model)
        let image = try buffer()
        CVPixelBufferLockBaseAddress(image, [])
        CVPixelBufferGetBaseAddress(image)?.storeBytes(of: UInt8(0), as: UInt8.self)
        CVPixelBufferUnlockBaseAddress(image, [])
        for i in 0..<2 { _ = worker.process(image, faces: [face], quality: 0.8, timestamp: Double(i)) }
        let rejected = worker.process(image, faces: [face], quality: 0.1, timestamp: 2)
        #expect(rejected.recognitionDiagnostics?.score == nil && rejected.recognitionDiagnostics?.streak == 0)
        #expect(rejected.recognitionDiagnostics?.rejection != nil && model.calls == 2)
        for i in 3...5 {
            let result = worker.process(image, faces: [face], quality: 0.8, timestamp: Double(i))
            #expect(result.recognitionDiagnostics?.streak == i - 2)
            #expect(result.complete == (i == 5))
            #expect(!result.text.hasPrefix("Match"))
        }
        let stale = worker.process(image, faces: [face], quality: 0.8, timestamp: 6)
        #expect(stale.complete && stale.text.hasPrefix("Inconclusive"))
        #expect(stale.recognitionDiagnostics?.freshFrame == false && stale.recognitionDiagnostics?.score == nil)
        #expect(model.calls == 5) // completed attempt never silently compares another person
    }

    @Test func nonmatchAndLongGapBreakConsecutiveThresholdPasses() {
        var verifier = VerificationAccumulator()
        #expect(verifier.observe(score: 0.8, timestamp: 0) == .checking)
        #expect(verifier.observe(score: 0.9, timestamp: 0.5) == .checking)
        #expect(verifier.observe(score: 0.1, timestamp: 1) == .checking)
        #expect(verifier.streak == 0)
        _ = verifier.observe(score: 0.9, timestamp: 1.5)
        _ = verifier.observe(score: 0.9, timestamp: 2)
        #expect(verifier.observe(score: 0.9, timestamp: 5) == .checking)
        #expect(verifier.streak == 1)
        #expect(verifier.observe(score: 0.9, timestamp: 5.5) == .checking)
        #expect(verifier.observe(score: 0.9, timestamp: 6) == .match) // math-only threshold event, never production identity acceptance
    }

    @Test func corruptAndStaleProfilesFailBeforeModelInference() throws {
        let original = try EnrollmentProfile(model: .sface, embedding: unit())
        let encoded = try JSONEncoder().encode(original)
        let image = try buffer()
        for stale in [false, true] {
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            if stale {
                var model = try #require(object["model"] as? [String: Any]); model["pipelineVersion"] = 99; object["model"] = model
            } else { object["embedding"] = [Float](repeating: 0, count: 128) }
            let invalid = try JSONDecoder().decode(EnrollmentProfile.self, from: JSONSerialization.data(withJSONObject: object))
            let model = BufferReadingTestModel()
            let worker = RecognitionPipeline(mode: .verify, profile: invalid, model: model)
            let result = worker.process(image, faces: [face], quality: 0.8, timestamp: 0)
            #expect(result.complete && result.text.hasPrefix("Error:"))
            #expect(result.recognitionDiagnostics?.score == nil && model.calls == 0)
        }
    }

    @Test func centroidChangesDecisionBoundaryWithoutAnyCosineImplementationBug() throws {
        let common: Float = 0.34
        let rest = sqrt(1 - common * common)
        func sample(_ x: Float, _ y: Float) -> [Float] {
            var v = [Float](repeating: 0, count: 128)
            v[0] = common; v[1] = rest * x; v[2] = rest * y
            return v
        }
        let front = sample(1, 0)
        let sideA = sample(0.5, sqrt(0.75)), sideB = sample(0.5, -sqrt(0.75))
        let samples = [front, front, sideA, sideA, sideB, sideB]
        var transaction = EnrollmentTransaction()
        for vector in samples {
            #expect(try Embedding.cosine(unit(), vector) < VerificationPolicy.sface.threshold)
            try transaction.append(vector) // all pass the existing sample-consistency gate
        }
        let centroid = try Embedding.centroid(samples)
        #expect(try Embedding.cosine(unit(), centroid) > VerificationPolicy.sface.threshold)
        // Geometric counterexample only; test vectors are not labeled real people.
    }

    @Test func exactOutputContractRejectsMissingWrongShapeTypeNonfiniteAndZero() throws {
        #expect(throws: (any Error).self) { try SFaceTensorContract.normalizedOutput(nil) }
        #expect(throws: (any Error).self) { try SFaceTensorContract.normalizedOutput(MLFeatureValue(string: "wrong type")) }
        for (shape, dtype) in [([128] as [NSNumber], MLMultiArrayDataType.float32), ([1,128], .double), ([2,64], .float32)] {
            let array = try MLMultiArray(shape: shape, dataType: dtype)
            for i in 0..<array.count { array[i] = 1 }
            #expect(throws: (any Error).self) { try SFaceTensorContract.normalizedOutput(MLFeatureValue(multiArray: array)) }
        }
        let array = try MLMultiArray(shape: [1,128], dataType: .float32)
        for i in 0..<128 { array[i] = 0 }
        #expect(throws: (any Error).self) { try SFaceTensorContract.normalizedOutput(MLFeatureValue(multiArray: array)) }
        array[0] = NSNumber(value: Float.nan)
        #expect(throws: (any Error).self) { try SFaceTensorContract.normalizedOutput(MLFeatureValue(multiArray: array)) }
        array[0] = 2
        let unit = try SFaceTensorContract.normalizedOutput(MLFeatureValue(multiArray: array))
        #expect(unit.count == 128 && unit[0] == 1)
    }

    @Test func rgbTensorUsesByteRangeChannelsAndTopRowWithoutExtraScaling() throws {
        var rgba = [UInt8](repeating: 0, count: 112 * 112 * 4)
        rgba[0] = 11; rgba[1] = 22; rgba[2] = 33; rgba[3] = 255
        let bottom = 111 * 112 * 4
        rgba[bottom] = 44; rgba[bottom+1] = 55; rgba[bottom+2] = 66
        let rgb = try SFaceTensorContract.channelsFirstRGB(rgba)
        #expect(rgb[0] == 11 && rgb[112*112] == 22 && rgb[2*112*112] == 33)
        #expect(rgb[111*112] == 44 && rgb[112*112+111*112] == 55)
        try SFaceTensorContract.validateInput(rgb)
        #expect(throws: (any Error).self) { try SFaceTensorContract.validateInput([-1]) }
        var bad = rgb; bad[0] = 256
        #expect(throws: (any Error).self) { try SFaceTensorContract.validateInput(bad) }
    }

    @Test func fivePointAlignmentMatchesCanonicalGeometryAndRejectsBadCrops() throws {
        let source = FaceAlignment.canonical.map { CGPoint(x: $0.x * 2 + 100, y: $0.y * 2 + 80) }
        let (transform, rms) = try FaceAlignment.transform(source: source, extent: CGRect(x: 0, y: 0, width: 640, height: 480))
        #expect(rms < 1e-9)
        #expect(transform.a * transform.d - transform.b * transform.c > 0)
        for (point, target) in zip(source, FaceAlignment.canonical) {
            let mapped = point.applying(transform)
            #expect(hypot(mapped.x-target.x, mapped.y-target.y) < 1e-9)
        }
        for radians in [-0.1, 0.1] {
            let rotation = CGAffineTransform(a: 2*cos(radians), b: 2*sin(radians), c: -2*sin(radians), d: 2*cos(radians), tx: 200, ty: 140)
            let rotated = FaceAlignment.canonical.map { $0.applying(rotation) }
            let (correction, error) = try FaceAlignment.transform(source: rotated, extent: CGRect(x: 0,y: 0,width: 640,height: 480))
            #expect(error < 1e-9)
            for (point, expected) in zip(rotated, FaceAlignment.canonical) {
                let p = point.applying(correction)
                #expect(hypot(p.x-expected.x, p.y-expected.y) < 1e-9)
            }
        }
        let normalized = FaceAlignment.imagePoint(CGPoint(x: 0.5, y: 0.5), boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5), extent: CGRect(x: 10, y: 20, width: 640, height: 480))
        #expect(abs(normalized.x - 298) < 1e-9 && abs(normalized.y - 236) < 1e-9)
        var reversed = source; reversed.swapAt(0,1)
        #expect(throws: (any Error).self) { try FaceAlignment.transform(source: reversed, extent: CGRect(x: 0,y: 0,width: 640,height: 480)) }
        let edge = FaceAlignment.canonical.map { CGPoint(x: $0.x - 30, y: $0.y) }
        #expect(throws: (any Error).self) { try FaceAlignment.transform(source: edge, extent: CGRect(x: 0,y: 0,width: 112,height: 112)) }
    }

    @Test @MainActor func cancellationClearsDiagnosticsAndRetryUsesANewPipeline() throws {
        let camera = CameraController()
        camera.report("Inconclusive — stopped attempt")
        camera.stop(wait: true)
        #expect(!camera.session.isRunning && camera.recognitionDiagnostics == nil && !camera.completed)
        let model = BufferReadingTestModel()
        let first = try pipeline(model), retry = try pipeline(model)
        let image = try buffer()
        CVPixelBufferLockBaseAddress(image, [])
        CVPixelBufferGetBaseAddress(image)?.storeBytes(of: UInt8(0), as: UInt8.self)
        CVPixelBufferUnlockBaseAddress(image, [])
        _ = first.process(image, faces: [face], quality: 0.8, timestamp: 0)
        _ = first.process(image, faces: [face], quality: 0.8, timestamp: 1)
        let result = retry.process(image, faces: [face], quality: 0.8, timestamp: 2)
        #expect(result.recognitionDiagnostics?.streak == 1 && !result.complete)
    }
}

// Test-only model reads a marker from the supplied buffer to expose accidental
// cached-buffer/output reuse. No real images or identity inference are simulated.
private final class BufferReadingTestModel: FaceEmbeddingModel {
    private(set) var calls = 0
    func embedding(from buffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float] {
        calls += 1
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let marker = CVPixelBufferGetBaseAddress(buffer)?.load(as: UInt8.self) ?? 0
        var vector = [Float](repeating: 0, count: 128)
        vector[marker == 0 ? 0 : 1] = 1
        return vector
    }
}
