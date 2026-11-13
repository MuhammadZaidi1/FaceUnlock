import AVFoundation
import RecognitionCore
import Vision
import FaceModel

struct RecognitionFrameResult {
    let text: String
    var complete = false
    var candidate: EnrollmentProfile?
}

enum RecognitionMode { case enroll, verify }

/// Used exclusively on the camera queue. Production has only the real SFace implementation.
final class RecognitionPipeline {
    private let mode: RecognitionMode
    private let profile: EnrollmentProfile?
    private let model: FaceEmbeddingModel
    private var enrollment = EnrollmentTransaction()
    private var verification = VerificationAccumulator()
    private var startedAt: TimeInterval?
    private var lastSample = -Double.infinity

    init(mode: RecognitionMode, profile: EnrollmentProfile?, model: FaceEmbeddingModel = SFaceModel()) {
        self.mode = mode
        self.profile = profile
        self.model = model
    }

    func prepare() throws { try model.prepare() }
    func interrupt() { verification.resetStreak() }

    func process(_ buffer: CVPixelBuffer, faces: [VNFaceObservation], quality: Float?, timestamp: TimeInterval) -> RecognitionFrameResult {
        if startedAt == nil { startedAt = timestamp }
        let duration = timestamp - (startedAt ?? timestamp)
        if duration > (mode == .verify ? 20 : 90) {
            return RecognitionFrameResult(text: mode == .verify ? "No match — verification timed out." : "Enrollment timed out. Existing enrollment is unchanged.", complete: true)
        }
        guard faces.count == 1, let face = faces.first else {
            verification.resetStreak()
            return RecognitionFrameResult(text: faces.isEmpty ? "Looking for face" : "Only one person should be in view.")
        }
        do {
            let w = face.boundingBox.width * Double(CVPixelBufferGetWidth(buffer))
            let h = face.boundingBox.height * Double(CVPixelBufferGetHeight(buffer))
            guard w >= 100, h >= 100 else { return reject("Move closer so your face fills more of the preview.") }
            guard let quality, quality >= 0.4 else {
                return reject("Face quality is low. Improve lighting, uncover your face, and hold still.")
            }
            let yaw = face.yaw?.doubleValue ?? 0
            let roll = face.roll?.doubleValue ?? 0
            let pitch = face.pitch?.doubleValue ?? 0
            guard abs(yaw) <= 0.35, abs(roll) <= 0.2, abs(pitch) <= 0.25 else {
                return reject("Face the camera with only a slight head turn.")
            }
            if mode == .enroll {
                let count = enrollment.samples.count
                let poseOK = count < 2 ? abs(yaw) < 0.1 : (count < 4 ? yaw >= 0.1 && yaw <= 0.3 : yaw <= -0.1 && yaw >= -0.3)
                guard poseOK else {
                    let wrongSide = (count >= 2 && count < 4 && yaw < -0.1) || (count >= 4 && yaw > 0.1)
                    return reject(wrongSide ? "\(count) of 6 · Turn slightly toward the other side." : instruction)
                }
                guard timestamp - lastSample >= 0.7 else { return RecognitionFrameResult(text: instruction) }
            }
            let vector = try model.embedding(from: buffer, face: face)
            switch mode {
            case .enroll:
                try enrollment.append(vector)
                lastSample = timestamp
                if enrollment.samples.count == EnrollmentTransaction.requiredSamples {
                    let candidate = try EnrollmentProfile(model: .sface, embedding: Embedding.centroid(enrollment.samples))
                    return RecognitionFrameResult(text: "6 of 6 samples ready. Review and Save Enrollment, or Cancel.", complete: true, candidate: candidate)
                }
                return RecognitionFrameResult(text: instruction)
            case .verify:
                guard let profile else { throw RecognitionError.noEnrollment }
                try profile.validate(for: .sface)
                let score = try Embedding.cosine(profile.embedding, vector)
                switch verification.observe(score: score, timestamp: timestamp) {
                case .checking: return RecognitionFrameResult(text: "Checking — keep facing the camera…")
                case .match: return RecognitionFrameResult(text: "Match — prototype face comparison only.", complete: true)
                case .noMatch: return RecognitionFrameResult(text: "No match", complete: true)
                }
            }
        } catch let error as FaceQualityError {
            return reject(error.localizedDescription)
        } catch RecognitionError.inconsistentSamples {
            return reject("Samples differ from the first face. Keep the same person in view, or Cancel and retry.")
        } catch {
            return RecognitionFrameResult(text: "Error: \(error.localizedDescription)", complete: true)
        }
    }

    private func reject(_ text: String) -> RecognitionFrameResult {
        verification.resetStreak()
        return RecognitionFrameResult(text: text)
    }

    private var instruction: String {
        let n = enrollment.samples.count
        let pose = n < 2 ? "Look straight ahead and hold still." : (n < 4 ? "Turn your head slightly one way." : "Turn slightly the opposite way.")
        return "\(n) of 6 samples · \(pose)"
    }
}
