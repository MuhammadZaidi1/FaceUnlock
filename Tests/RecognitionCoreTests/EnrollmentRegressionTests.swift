import AVFoundation
import FaceModel
@testable import FaceUnlock
import RecognitionCore
import Testing
import Vision

struct EnrollmentRegressionTests {
    private func image() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        return try #require(buffer)
    }
    private func face(yaw: Double?) -> VNFaceObservation {
        VNFaceObservation(requestRevision: VNRequestRevisionUnspecified,
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            roll: 0, yaw: yaw.map(NSNumber.init(value:)), pitch: 0)
    }
    private func unit(_ index: Int = 0) -> [Float] {
        var vector = [Float](repeating: 0, count: 128); vector[index] = 1; return vector
    }

    @Test func sixSamplesProgressThroughBothSignedTurns() throws {
        let pipeline = RecognitionPipeline(mode: .enroll, profile: nil, model: EnrollmentModel(vector: unit()))
        let buffer = try image()
        var last = RecognitionFrameResult(text: "")
        for (index, yaw) in [0.0, 0.0, 0.15, 0.2, -0.15, -0.2].enumerated() {
            last = pipeline.process(buffer, faces: [face(yaw: yaw)], quality: 0.8, timestamp: Double(index))
            #expect(last.diagnostics?.accepted == index + 1)
            #expect(last.complete == (index == 5))
        }
        #expect(last.candidate != nil)
    }

    @Test func missingYawAfterTwoReproducesLegacyDeadlockAndIsNowExplicit() throws {
        let pipeline = RecognitionPipeline(mode: .enroll, profile: nil, model: EnrollmentModel(vector: unit()))
        let buffer = try image()
        _ = pipeline.process(buffer, faces: [face(yaw: 0)], quality: 0.8, timestamp: 0)
        _ = pipeline.process(buffer, faces: [face(yaw: 0)], quality: 0.8, timestamp: 1)
        for i in 2...8 {
            let result = pipeline.process(buffer, faces: [face(yaw: nil)], quality: 0.8, timestamp: Double(i))
            #expect(result.diagnostics?.accepted == 2)
            #expect(result.diagnostics?.pose.yaw == nil)
            #expect(result.diagnostics?.canOfferGuided == true)
            #expect(result.text.contains("unavailable"))
        }
        // A real side measurement resumes the same transaction without resetting it.
        let result = pipeline.process(buffer, faces: [face(yaw: 0.2)], quality: 0.8, timestamp: 9)
        #expect(result.diagnostics?.accepted == 3)
    }

    @Test func missingYawIsNotAFrontPoseAndDetectorPoseIsPreserved() throws {
        let pipeline = RecognitionPipeline(mode: .enroll, profile: nil, model: EnrollmentModel(vector: unit()))
        let buffer = try image()
        let missing = pipeline.process(buffer, faces: [face(yaw: nil)], quality: 0.8, timestamp: 0)
        #expect(missing.diagnostics?.accepted == 0)
        let detectorPose = FacePose(yaw: 0, pitch: 0, roll: 0)
        let accepted = pipeline.process(buffer, faces: [face(yaw: nil)], quality: 0.8, timestamp: 1, detectorPose: detectorPose)
        #expect(accepted.diagnostics?.accepted == 1)
        #expect(accepted.diagnostics?.pose.yaw == 0)
    }

    @Test func rangesOverlapAndBoundariesDoNotDeadlock() {
        for yaw in [0.1, 0.3, -0.1, -0.3] {
            let pose = FacePose(yaw: yaw, pitch: 0, roll: 0)
            #expect(EnrollmentPosePolicy.globalRejection(pose) == nil)
            #expect(EnrollmentPosePolicy.rejection(pose, count: yaw > 0 ? 2 : 4, mode: .validated) == nil)
        }
        #expect(EnrollmentPosePolicy.rejection(FacePose(yaw: 0.1, pitch: 0, roll: 0), count: 0, mode: .validated) != nil)
        #expect(EnrollmentPosePolicy.rejection(FacePose(yaw: 0.099, pitch: 0, roll: 0), count: 0, mode: .validated) == nil)
        #expect(EnrollmentPosePolicy.globalRejection(FacePose(yaw: 0.35, pitch: 0, roll: 0)) == nil)
        #expect(EnrollmentPosePolicy.globalRejection(FacePose(yaw: 0.35.nextUp, pitch: 0, roll: 0)) != nil)
        #expect(EnrollmentPosePolicy.rejection(FacePose(yaw: -0.2, pitch: 0, roll: 0), count: 2, mode: .validated) != nil)
        #expect(EnrollmentPosePolicy.rejection(FacePose(yaw: 0.2, pitch: 0, roll: 0), count: 4, mode: .validated) != nil)
    }

    @Test func radiansDegreesAndPreviewMirroringContract() {
        #expect(abs(FacePose.degrees(.pi / 4) - 45) < 1e-10)
        #expect(abs(FacePose.degrees(-.pi / 2) + 90) < 1e-10)
        #expect(CameraCoordinates.previewMirrored)
        #expect(!CameraCoordinates.captureMirrored)
        #expect(CameraCoordinates.visionOrientation == .up)
        // Policies operate on the detector's raw signed pose, never on the mirrored preview.
        #expect(EnrollmentPosePolicy.rejection(FacePose(yaw: 0.2, pitch: 0, roll: 0), count: 2, mode: .validated) == nil)
        #expect(EnrollmentPosePolicy.rejection(FacePose(yaw: -0.2, pitch: 0, roll: 0), count: 2, mode: .validated) != nil)
    }

    @Test func coarseYawCannotSneakPastGlobalGateAndOffersExplicitFallback() throws {
        let pipeline = RecognitionPipeline(mode: .enroll, profile: nil, model: EnrollmentModel(vector: unit()))
        let buffer = try image()
        for i in 0..<2 { _ = pipeline.process(buffer, faces: [face(yaw: 0)], quality: 0.8, timestamp: Double(i)) }
        var result = RecognitionFrameResult(text: "")
        for i in 2..<10 {
            result = pipeline.process(buffer, faces: [face(yaw: i % 2 == 0 ? 0 : .pi / 4)], quality: 0.8, timestamp: Double(i))
            #expect(result.diagnostics?.accepted == 2)
        }
        #expect(result.diagnostics?.canOfferGuided == true)
        #expect(!result.complete)
    }

    @Test func explicitGuidedModeAcceptsQualitySamplesWithoutClaimingTurns() throws {
        let buffer = try image()
        let pipeline = RecognitionPipeline(mode: .enroll, profile: nil, model: EnrollmentModel(vector: unit()), poseMode: .guided)
        var result = RecognitionFrameResult(text: "")
        for i in 0..<6 {
            result = pipeline.process(buffer, faces: [face(yaw: nil)], quality: 0.8, timestamp: Double(i))
        }
        #expect(result.complete && result.candidate != nil)
        #expect(result.text.contains("NOT validated"))
        #expect(result.diagnostics?.poseMode == .guided)
    }

    @Test func spacingWrongDirectionQualityAndIdentityStillReject() throws {
        let buffer = try image()
        let model = EnrollmentModel(vector: unit())
        let pipeline = RecognitionPipeline(mode: .enroll, profile: nil, model: model)
        _ = pipeline.process(buffer, faces: [face(yaw: 0)], quality: 0.8, timestamp: 0)
        #expect(pipeline.process(buffer, faces: [face(yaw: 0)], quality: 0.8, timestamp: 0.5).diagnostics?.accepted == 1)
        _ = pipeline.process(buffer, faces: [face(yaw: 0)], quality: 0.8, timestamp: 1)
        #expect(pipeline.process(buffer, faces: [face(yaw: -0.2)], quality: 0.8, timestamp: 2).diagnostics?.accepted == 2)
        #expect(pipeline.process(buffer, faces: [face(yaw: 0.2)], quality: 0.1, timestamp: 3).diagnostics?.accepted == 2)
        model.vector = unit(1)
        let mismatch = pipeline.process(buffer, faces: [face(yaw: 0.2)], quality: 0.8, timestamp: 4)
        #expect(mismatch.diagnostics?.accepted == 2 && mismatch.text.contains("differ"))
        model.error = FaceQualityError(reason: "Image is blurry. Hold still.")
        let blurry = pipeline.process(buffer, faces: [face(yaw: 0.2)], quality: 0.8, timestamp: 5)
        #expect(blurry.diagnostics?.rejection?.contains("blurry") == true)
        model.error = RecognitionError.modelUnavailable
        let fatal = pipeline.process(buffer, faces: [face(yaw: 0.2)], quality: 0.8, timestamp: 6)
        #expect(fatal.complete && fatal.candidate == nil)
    }

    @Test @MainActor func cameraErrorAndCancellationStopAnIdleSessionWithoutPermissions() {
        let camera = CameraController()
        camera.report("Error: camera unavailable")
        #expect(!camera.session.isRunning && camera.completed && camera.candidate == nil)
        camera.stop(wait: true)
        #expect(!camera.session.isRunning && !camera.completed && camera.diagnostics == nil)
    }
}

private final class EnrollmentModel: FaceEmbeddingModel {
    var vector: [Float]
    var error: Error?
    init(vector: [Float]) { self.vector = vector }
    func embedding(from buffer: CVPixelBuffer, face: VNFaceObservation) throws -> [Float] {
        if let error { throw error }; return vector
    }
}
