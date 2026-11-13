import Foundation

public struct VerificationPolicy {
    /// OpenCV SFace tutorial's cosine threshold. Not a probability or security guarantee.
    public static let sface = VerificationPolicy(threshold: 0.363)
    public let threshold: Double
    public let requiredMatches: Int
    public let maximumSamples: Int
    public let minimumFrameInterval: TimeInterval
    public init(threshold: Double, requiredMatches: Int = 3, maximumSamples: Int = 15,
                minimumFrameInterval: TimeInterval = 0.4) {
        precondition(threshold.isFinite && (-1...1).contains(threshold))
        precondition(requiredMatches > 0 && maximumSamples >= requiredMatches && minimumFrameInterval > 0)
        self.threshold = threshold
        self.requiredMatches = requiredMatches
        self.maximumSamples = maximumSamples
        self.minimumFrameInterval = minimumFrameInterval
    }
    public func accepts(_ score: Double) -> Bool { score.isFinite && score >= threshold && score <= 1 }
}

public enum VerificationDecision: Equatable { case checking, match, noMatch }

public struct VerificationAccumulator {
    public let policy: VerificationPolicy
    private var lastTime: TimeInterval = -.infinity
    private var count = 0
    private var streak = 0
    private var result: VerificationDecision = .checking
    public init(policy: VerificationPolicy = .sface) { self.policy = policy }
    public mutating func resetStreak() { streak = 0 }
    public mutating func observe(score: Double, timestamp: TimeInterval) -> VerificationDecision {
        guard result == .checking else { return result }
        guard timestamp.isFinite, timestamp - lastTime >= policy.minimumFrameInterval else { return .checking }
        lastTime = timestamp
        count += 1
        streak = policy.accepts(score) ? streak + 1 : 0
        if streak >= policy.requiredMatches { result = .match }
        else if count >= policy.maximumSamples { result = .noMatch }
        return result
    }
}

/// In-memory only. Limits persist across window dismissal, but not app relaunch.
public struct AttemptLimiter {
    private var starts: [TimeInterval] = []
    private var nextAttempt: TimeInterval = 0
    public init() {}
    public mutating func finish(at now: TimeInterval) { nextAttempt = max(nextAttempt, now + 5) }
    public mutating func begin(at now: TimeInterval) -> Bool {
        starts.removeAll { now - $0 >= 60 }
        guard now >= nextAttempt, starts.count < 3 else { return false }
        starts.append(now)
        nextAttempt = now + 5
        return true
    }
}
