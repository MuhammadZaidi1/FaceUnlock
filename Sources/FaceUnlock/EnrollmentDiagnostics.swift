import FaceModel
import Foundation
import RecognitionCore

/// Transient scalar diagnostics only. Never logged, persisted, or attached to a profile.
struct EnrollmentDiagnostics {
    var stage = "Waiting for frames"
    var accepted = 0
    var pose = FacePose(yaw: nil, pitch: nil, roll: nil)
    var expected = "Waiting"
    var rejection: String?
    var captureQuality: Float?
    var facePixels: String = "Unavailable"
    var modelQuality: FaceQualityMetrics?
    var processedFrames = 0
    var processedAt: TimeInterval = 0
    var poseMode = EnrollmentPoseMode.validated
    var canOfferGuided = false
}
