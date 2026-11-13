import Foundation

public enum EnrollmentPoseMode: String, Sendable {
    case validated
    case guided // Explicit user choice; never claims that a turn was measured.
}

public struct FacePose: Sendable {
    public let yaw: Double?
    public let pitch: Double?
    public let roll: Double?
    public init(yaw: Double?, pitch: Double?, roll: Double?) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }
    public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

public enum EnrollmentPosePolicy {
    public static let maximumYaw = 0.35
    public static let sideRange = 0.1...0.3
    public static func stage(_ count: Int) -> String {
        count >= 6 ? "Ready to save" : (count < 2 ? "Front" : (count < 4 ? "First slight turn" : "Opposite slight turn"))
    }
    public static func expected(_ count: Int, mode: EnrollmentPoseMode) -> String {
        if mode == .guided { return "Not validated — six quality samples with natural variation" }
        if count >= 6 { return "Complete" }
        return count < 2 ? "−5.73° < yaw < +5.73°" : (count < 4 ? "+5.73° … +17.19°" : "−17.19° … −5.73°")
    }
    public static func globalRejection(_ pose: FacePose) -> String? {
        for value in [pose.yaw, pose.pitch, pose.roll].compactMap({ $0 }) {
            if !value.isFinite { return "Pose estimate is invalid. Hold still or retry." }
        }
        if let yaw = pose.yaw, abs(yaw) > maximumYaw { return "Turn back slightly toward the camera." }
        if let pitch = pose.pitch, abs(pitch) > 0.25 { return "Keep your chin level." }
        if let roll = pose.roll, abs(roll) > 0.2 { return "Keep your head upright." }
        return nil
    }
    public static func rejection(_ pose: FacePose, count: Int, mode: EnrollmentPoseMode) -> String? {
        if let reason = globalRejection(pose) { return reason }
        guard mode == .validated else { return nil }
        guard let yaw = pose.yaw, yaw.isFinite else {
            return "Head-turn estimate unavailable. Retry, or explicitly choose guided samples with unvalidated turns."
        }
        if count < 2 { return abs(yaw) < 0.1 ? nil : "Look straight at the camera." }
        let expectedSign = count < 4 ? 1.0 : -1.0
        let directed = yaw * expectedSign
        if directed < -0.05 { return "Slowly turn toward the other side." }
        if directed < sideRange.lowerBound { return "Turn a little more, slowly." }
        if directed > sideRange.upperBound { return "Turn back slightly and hold still." }
        return nil
    }
}
