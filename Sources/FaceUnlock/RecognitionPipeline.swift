import AVFoundation
import RecognitionCore
import Vision
import FaceModel

struct RecognitionFrameResult {
    var text: String
    var complete = false
    var candidate: EnrollmentProfile?
    var diagnostics: EnrollmentDiagnostics?
    var rejection: String?
    var recognitionDiagnostics: RecognitionDiagnostics?
    var evaluation: EvaluationSnapshot?
}

enum RecognitionMode {
    case enroll, verify, evaluate
    var timeout: TimeInterval {
        switch self { case .enroll: return 90; case .verify: return 20; case .evaluate: return RecognitionEvaluation.timeout }
    }
}

/// Used exclusively on the camera queue. Production has only the real SFace implementation.
final class RecognitionPipeline {
    private let mode: RecognitionMode
    private let profile: EnrollmentProfile?
    private let model: FaceEmbeddingModel
    private var evaluationClock: (() -> TimeInterval)?
    private var evaluation = RecognitionEvaluation()
    var isEvaluation: Bool { mode == .evaluate }
    private var enrollment = EnrollmentTransaction()
    private var verification = VerificationAccumulator()
    private var startedAt: TimeInterval?
    private let poseMode: EnrollmentPoseMode
    private var didInvokeModel = false
    private var processedFrames = 0
    private var poseRejections = 0
    private var freshFrames = FreshFrameGate()
    private var processingTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval?
    private var currentScore: Double?
    private var freshFrame = false
    private var currentFrameTimestamp: TimeInterval?
    private var evaluatedFrames = 0
    private var terminalResult: RecognitionFrameResult?
    private var lastSample = -Double.infinity

    init(mode: RecognitionMode, profile: EnrollmentProfile?, model: FaceEmbeddingModel = SFaceModel(), poseMode: EnrollmentPoseMode = .validated) {
        self.mode = mode
        self.profile = profile
        self.model = model
        self.poseMode = poseMode
    }

    func prepare() throws { try model.prepare() }
    func beginEvaluation(at now: TimeInterval, clock: (() -> TimeInterval)? = nil) {
        if isEvaluation { evaluationClock = clock; evaluation.begin(at: now) }
    }
    func interrupt() { verification.resetStreak(); if isEvaluation { evaluation.breakSequence() } }

    func evaluationSnapshot(at now: TimeInterval) -> EvaluationSnapshot? {
        isEvaluation ? evaluation.snapshot(at: now) : nil
    }

    func finishEvaluation(_ phase: EvaluationPhase, at now: TimeInterval) -> EvaluationSnapshot? {
        guard isEvaluation else { return nil }
        evaluation.finish(phase, at: now)
        return evaluation.snapshot(at: now)
    }

    func rejectEvaluationFrame(_ reason: String, at now: TimeInterval) -> RecognitionFrameResult {
        processingTime = now
        return finalizeEvaluation(reject(reason), at: now)
    }

    private func finalizeEvaluation(_ original: RecognitionFrameResult, at now: TimeInterval) -> RecognitionFrameResult {
        guard isEvaluation else { return original }
        var result = original
        _ = evaluation.expire(at: now)
        if original.complete && evaluation.phase == .collecting {
            evaluation.reject(original.rejection ?? original.text, at: now)
            evaluation.finish(.failed, at: now)
        }
        result.evaluation = evaluation.snapshot(at: now)
        switch evaluation.phase {
        case .collecting: break
        case .completed: result = RecognitionFrameResult(text: "Evaluation complete: 15/15 comparisons. Experimental — not an authentication decision.", complete: true, evaluation: result.evaluation)
        case .timedOut: result.text = "Evaluation timed out. Partial results only; no authentication decision."; result.complete = true
        case .failed:
            if !original.complete { result.text = "Evaluation failed. Partial results only; close or retry." }
            result.complete = true
        }
        if result.complete { terminalResult = result }
        return result
    }

    func process(_ buffer: CVPixelBuffer, faces: [VNFaceObservation], quality: Float?, timestamp: TimeInterval, detectorPose: FacePose? = nil, frameTimestamp: TimeInterval? = nil) -> RecognitionFrameResult {
        if var terminal = terminalResult {
            terminal.recognitionDiagnostics?.freshFrame = false
            terminal.recognitionDiagnostics?.score = nil
            terminal.recognitionDiagnostics?.passedThreshold = nil
            return terminal
        }
        processingTime = isEvaluation ? (evaluationClock?() ?? timestamp) : timestamp
        didInvokeModel = false
        currentScore = nil
        currentFrameTimestamp = frameTimestamp ?? timestamp
        freshFrame = freshFrames.accept(frameTimestamp ?? timestamp)
        processedFrames += 1
        let face = faces.count == 1 ? faces.first : nil
        let pose = detectorPose ?? FacePose(yaw: face?.yaw?.doubleValue, pitch: face?.pitch?.doubleValue, roll: face?.roll?.doubleValue)
        var result: RecognitionFrameResult
        if isEvaluation && evaluation.expire(at: processingTime) {
            result = RecognitionFrameResult(text: "Evaluation timed out.", complete: true)
        } else if !freshFrame {
            result = reject("Waiting for a fresh camera frame; repeated or out-of-order frame rejected.")
        } else {
            if let lastFrameTime, timestamp - lastFrameTime > 2 { verification.resetStreak() }
            lastFrameTime = timestamp
            result = processFrame(buffer, faces: faces, quality: quality, timestamp: timestamp, pose: pose)
        }
        if mode == .verify {
            result.recognitionDiagnostics = RecognitionDiagnostics(score: currentScore, threshold: VerificationPolicy.sface.threshold,
                passedThreshold: currentScore.map(VerificationPolicy.sface.accepts), streak: verification.streak,
                evaluatedFrames: evaluatedFrames, freshFrame: freshFrame, frameTimestamp: currentFrameTimestamp,
                rejection: result.rejection, model: .sface)
        }
        if mode == .enroll {
            let pixels = face.map { "\(Int($0.boundingBox.width * Double(CVPixelBufferGetWidth(buffer)))) × \(Int($0.boundingBox.height * Double(CVPixelBufferGetHeight(buffer)))) px" } ?? "Unavailable"
            result.diagnostics = EnrollmentDiagnostics(stage: EnrollmentPosePolicy.stage(enrollment.samples.count), accepted: enrollment.samples.count,
                pose: pose, expected: EnrollmentPosePolicy.expected(enrollment.samples.count, mode: poseMode), rejection: result.rejection,
                captureQuality: quality, facePixels: pixels, modelQuality: didInvokeModel ? model.lastQualityMetrics : nil,
                processedFrames: processedFrames, processedAt: timestamp, poseMode: poseMode,
                canOfferGuided: faces.count == 1 && (quality ?? 0) >= 0.4 && (pose.yaw == nil || poseRejections >= 6))
        }
        if isEvaluation { result = finalizeEvaluation(result, at: evaluationClock?() ?? timestamp) }
        if result.complete { terminalResult = result }
        return result
    }

    private func processFrame(_ buffer: CVPixelBuffer, faces: [VNFaceObservation], quality: Float?, timestamp: TimeInterval, pose: FacePose) -> RecognitionFrameResult {
        if startedAt == nil { startedAt = timestamp }
        let duration = timestamp - (startedAt ?? timestamp)
        if duration > mode.timeout {
            return RecognitionFrameResult(text: mode == .verify ? "No match — verification timed out." : "Enrollment timed out. Existing enrollment is unchanged.", complete: true)
        }
        guard faces.count == 1, let face = faces.first else {
            verification.resetStreak()
            return reject(faces.isEmpty ? "Looking for face" : "Only one face can be visible.")
        }
        do {
            if mode != .enroll {
                guard let profile else { throw RecognitionError.noEnrollment }
                try profile.validate(for: .sface)
            }
            let w = face.boundingBox.width * Double(CVPixelBufferGetWidth(buffer))
            let h = face.boundingBox.height * Double(CVPixelBufferGetHeight(buffer))
            guard w >= 100, h >= 100 else { return reject("Move closer so your face fills more of the preview.") }
            guard let quality, quality >= 0.4 else {
                return reject("Face quality is low. Improve lighting, uncover your face, and hold still.")
            }
            if let reason = EnrollmentPosePolicy.globalRejection(pose) {
                poseRejections += 1
                return reject(reason)
            }
            if mode == .enroll {
                if let reason = EnrollmentPosePolicy.rejection(pose, count: enrollment.samples.count, mode: poseMode) {
                    poseRejections += 1
                    return reject(reason)
                }
                guard timestamp - lastSample >= 0.7 else { return reject("Hold still while the next distinct sample arrives.") }
            }
            didInvokeModel = true
            let vector = try model.embedding(from: buffer, face: face)
            switch mode {
            case .enroll:
                try enrollment.append(vector)
                poseRejections = 0
                lastSample = timestamp
                if enrollment.samples.count == EnrollmentTransaction.requiredSamples {
                    let candidate = try EnrollmentProfile(model: .sface, embedding: Embedding.centroid(enrollment.samples))
                    return RecognitionFrameResult(text: poseMode == .guided ? "6 of 6 quality samples ready. Head turns were NOT validated. Save or Cancel." : "6 of 6 samples ready. Save Enrollment, or Cancel.", complete: true, candidate: candidate)
                }
                return RecognitionFrameResult(text: instruction)
            case .verify, .evaluate:
                guard let profile else { throw RecognitionError.noEnrollment }
                try profile.validate(for: .sface)
                guard vector.count == ModelIdentity.sface.dimensions else { throw RecognitionError.invalidEmbedding }
                let score = try Embedding.cosine(profile.embedding, vector)
                currentScore = score
                evaluatedFrames += 1
                if isEvaluation {
                    let accepted = try evaluation.record(score: score, captureTimestamp: currentFrameTimestamp ?? timestamp, at: evaluationClock?() ?? timestamp)
                    return RecognitionFrameResult(text: accepted ? "\(evaluation.snapshot(at: timestamp).validCount)/15 quality-approved comparisons. Hold still." : "Waiting for a fresh, sufficiently spaced comparison.")
                }
                switch verification.observe(score: score, timestamp: timestamp) {
                case .checking: return RecognitionFrameResult(text: "Checking — keep facing the camera…")
                case .match: return RecognitionFrameResult(text: "Inconclusive — three threshold passes observed. Identity acceptance is disabled while the false acceptance is investigated.", complete: true)
                case .noMatch: return RecognitionFrameResult(text: "No match", complete: true)
                }
            }
        } catch let error as FaceQualityError {
            return reject(error.localizedDescription)
        } catch RecognitionError.inconsistentSamples {
            return reject("Samples differ from the first face. Keep the same person in view, or Cancel and retry.")
        } catch {
            return RecognitionFrameResult(text: "Error: \(error.localizedDescription)", complete: true, rejection: error.localizedDescription)
        }
    }

    private func reject(_ text: String) -> RecognitionFrameResult {
        verification.resetStreak()
        if isEvaluation { evaluation.reject(text, at: processingTime) }
        return RecognitionFrameResult(text: text, rejection: text)
    }

    private var instruction: String {
        let n = enrollment.samples.count
        if poseMode == .guided { return "\(n) of 6 quality samples · Vary your pose naturally. Head turns are not validated." }
        let pose = n < 2 ? "Look straight ahead and hold still." : (n < 4 ? "Slowly turn to one side; reverse if asked." : "Slowly turn toward the opposite side.")
        return "\(n) of 6 samples · \(pose)"
    }
}
