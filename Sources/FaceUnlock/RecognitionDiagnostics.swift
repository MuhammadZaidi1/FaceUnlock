import Foundation
import RecognitionCore

/// Current frame's scalar decision trace. No vectors, inputs, template identifiers,
/// images, disk output, console output, or score history.
struct RecognitionDiagnostics {
    var score: Double?
    let threshold: Double
    var passedThreshold: Bool?
    let streak: Int
    let evaluatedFrames: Int
    var freshFrame: Bool
    let frameTimestamp: TimeInterval?
    let rejection: String?
    let model: ModelIdentity
}
