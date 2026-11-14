import Foundation

public enum EvaluationPhase: String, Sendable {
    case collecting, completed, timedOut, failed
}

public struct SimilarityStatistics: Sendable {
    public let minimum: Double
    public let maximum: Double
    public let mean: Double
    public let median: Double
    /// Population standard deviation of this attempt's scores (divisor N).
    public let standardDeviation: Double

    public init?(scores: [Double]) {
        guard !scores.isEmpty, scores.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else { return nil }
        let sorted = scores.sorted()
        minimum = sorted[0]; maximum = sorted[sorted.count - 1]
        let average = scores.reduce(0, +) / Double(scores.count)
        mean = average
        median = sorted.count % 2 == 0 ? (sorted[sorted.count/2 - 1] + sorted[sorted.count/2]) / 2 : sorted[sorted.count/2]
        standardDeviation = sqrt(scores.reduce(0) { $0 + pow($1 - average, 2) } / Double(scores.count))
    }
}

public struct ExperimentalThresholdResult: Sendable {
    public let threshold: Double
    public let passingCount: Int
    public let passingPercentage: Double
    public let threeConsecutivePasses: Bool
}

/// Transient values only: intentionally not Codable and never written to a store.
public struct EvaluationSnapshot: Sendable {
    public let phase: EvaluationPhase
    public let scores: [Double]
    public let currentScore: Double?
    public let rejectedReasons: [String: Int]
    public let duration: TimeInterval
    private let events: [Double?] // nil breaks the hypothetical streak; never denotes a score.
    public var validCount: Int { scores.count }
    public var rejectedCount: Int { rejectedReasons.values.reduce(0, +) }
    public var statistics: SimilarityStatistics? { SimilarityStatistics(scores: scores) }
    public static let candidateThresholds = [0.363, 0.500, 0.600, 0.700]

    fileprivate init(phase: EvaluationPhase, scores: [Double], currentScore: Double?, rejectedReasons: [String:Int], duration: TimeInterval, events: [Double?]) {
        self.phase = phase; self.scores = scores; self.currentScore = currentScore
        self.rejectedReasons = rejectedReasons; self.duration = duration; self.events = events
    }

    public func analyze(threshold: Double) -> ExperimentalThresholdResult? {
        guard threshold.isFinite, (-1...1).contains(threshold) else { return nil }
        let passing = scores.filter { $0 >= threshold }.count
        var streak = 0, wouldPass = false
        for event in events {
            if let score = event, score >= threshold { streak += 1 } else { streak = 0 }
            if streak >= 3 { wouldPass = true }
        }
        return ExperimentalThresholdResult(threshold: threshold, passingCount: passing,
            passingPercentage: scores.isEmpty ? 0 : Double(passing) / Double(scores.count) * 100,
            threeConsecutivePasses: wouldPass)
    }
}

public struct RecognitionEvaluation {
    public static let requiredComparisons = 15
    public static let timeout: TimeInterval = 45
    public static let minimumInterval: TimeInterval = 0.5
    private var scores: [Double] = []
    private var events: [Double?] = []
    private var rejections: [String:Int] = [:]
    private var startedAt: TimeInterval?
    private var endedAt: TimeInterval?
    private var lastAcceptedAt: TimeInterval?
    private var freshFrames = FreshFrameGate()
    private var currentScore: Double?
    public private(set) var phase = EvaluationPhase.collecting
    public init() {}

    public mutating func begin(at now: TimeInterval) {
        if startedAt == nil, now.isFinite { startedAt = now }
    }

    @discardableResult public mutating func expire(at now: TimeInterval) -> Bool {
        begin(at: now)
        if phase == .collecting, let startedAt, now - startedAt >= Self.timeout { finish(.timedOut, at: now) }
        return phase != .collecting
    }

    @discardableResult public mutating func record(score: Double, captureTimestamp: TimeInterval, at now: TimeInterval) throws -> Bool {
        guard !expire(at: now) else { return false }
        guard score.isFinite, (-1...1).contains(score) else { finish(.failed, at: now); throw RecognitionError.invalidEmbedding }
        guard freshFrames.accept(captureTimestamp) else { reject("Repeated, invalid, or out-of-order capture timestamp", at: now); return false }
        guard now.isFinite, now >= (startedAt ?? now), lastAcceptedAt.map({ now - $0 >= Self.minimumInterval }) ?? true else {
            reject("Comparison interval too short or processing clock invalid", at: now); return false
        }
        if let lastAcceptedAt, now - lastAcceptedAt > 2 { breakSequence() }
        scores.append(score); events.append(score); currentScore = score; lastAcceptedAt = now
        if scores.count == Self.requiredComparisons { finish(.completed, at: now) }
        return true
    }

    public mutating func reject(_ reason: String, at now: TimeInterval) {
        guard !expire(at: now) else { return }
        guard events.count < 256 else { finish(.failed, at: now); return }
        rejections[reason, default: 0] += 1
        currentScore = nil
        breakSequence()
    }

    public mutating func breakSequence() {
        if phase == .collecting { currentScore = nil }
        if phase == .collecting, events.count < 256 { events.append(nil) }
    }

    public mutating func finish(_ phase: EvaluationPhase, at now: TimeInterval) {
        guard self.phase == .collecting, phase != .collecting else { return }
        self.phase = phase == .completed && scores.count != Self.requiredComparisons ? .failed : phase
        if self.phase != .completed { currentScore = nil }
        endedAt = now.isFinite ? now : startedAt
    }

    public func snapshot(at now: TimeInterval) -> EvaluationSnapshot {
        let end = endedAt ?? now
        let duration = (end.isFinite && startedAt != nil) ? max(0, end - (startedAt ?? end)) : 0
        return EvaluationSnapshot(phase: phase, scores: scores, currentScore: currentScore,
            rejectedReasons: rejections, duration: duration, events: events)
    }
}
