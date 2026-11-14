import Foundation
import RecognitionCore
import Testing

struct RecognitionEvaluationTests {
    @Test func statisticsUsePopulationDeviationAndCorrectOddEvenMedians() throws {
        let even = try #require(SimilarityStatistics(scores: [-1, 0, 0.5, 1]))
        #expect(even.minimum == -1 && even.maximum == 1 && even.mean == 0.125 && even.median == 0.25)
        #expect(abs(even.standardDeviation - sqrt(0.546875)) < 1e-12)
        let odd = try #require(SimilarityStatistics(scores: [1, -1, 0]))
        #expect(odd.median == 0 && abs(odd.standardDeviation - sqrt(2.0/3)) < 1e-12)
        #expect(SimilarityStatistics(scores: [0.7])?.standardDeviation == 0)
        #expect(SimilarityStatistics(scores: []) == nil)
        #expect(SimilarityStatistics(scores: [.nan]) == nil)
        #expect(SimilarityStatistics(scores: [1.1]) == nil)
    }

    @Test func exactFifteenCompletionAndFrozenDuration() throws {
        var evaluation = RecognitionEvaluation()
        evaluation.begin(at: 10)
        for i in 0..<15 {
            #expect(try evaluation.record(score: 0.8, captureTimestamp: Double(i), at: Double(i)+10))
            #expect(evaluation.phase == (i == 14 ? .completed : .collecting))
        }
        #expect(try !evaluation.record(score: 0.1, captureTimestamp: 15, at: 25))
        let result = evaluation.snapshot(at: 100)
        #expect(result.validCount == 15 && result.rejectedCount == 0 && result.duration == 14)
        #expect(result.currentScore == 0.8)
    }

    @Test func experimentalCountsPercentagesAndThreePassSimulation() throws {
        var evaluation = RecognitionEvaluation()
        let pattern = [0.4, 0.5, 0.6, 0.7, 0.8]
        for i in 0..<15 { try evaluation.record(score: pattern[i % 5], captureTimestamp: Double(i), at: Double(i)) }
        let result = evaluation.snapshot(at: 14)
        for (threshold, count, streak) in [(0.363,15,true),(0.5,12,true),(0.6,9,true),(0.7,6,false),(0.75,3,false)] {
            let analysis = try #require(result.analyze(threshold: threshold))
            #expect(analysis.passingCount == count)
            #expect(abs(analysis.passingPercentage - Double(count)/15*100) < 1e-12)
            #expect(analysis.threeConsecutivePasses == streak)
        }
        #expect(result.analyze(threshold: .nan) == nil)
        #expect(result.analyze(threshold: 1.01) == nil)
        #expect(VerificationPolicy.sface.threshold == 0.363)
    }

    @Test func duplicateStaleInvalidAndTooFastFramesAreRejected() throws {
        var evaluation = RecognitionEvaluation()
        try evaluation.record(score: 0.8, captureTimestamp: 0, at: 0)
        #expect(try !evaluation.record(score: 0.8, captureTimestamp: 0, at: 1))
        #expect(try !evaluation.record(score: 0.8, captureTimestamp: -1, at: 2))
        #expect(try !evaluation.record(score: 0.8, captureTimestamp: .nan, at: 3))
        #expect(try evaluation.record(score: 0.8, captureTimestamp: 1, at: 3.2))
        #expect(try !evaluation.record(score: 0.8, captureTimestamp: 2, at: 3.3))
        #expect(try !evaluation.record(score: 0.8, captureTimestamp: 2, at: 4))
        let snapshot = evaluation.snapshot(at: 4)
        #expect(snapshot.validCount == 2 && snapshot.rejectedCount == 5 && snapshot.currentScore == nil)
    }

    @Test func rejectionsInterruptionsAndGapsBreakExperimentalStreaks() throws {
        var evaluation = RecognitionEvaluation()
        try evaluation.record(score: 0.8, captureTimestamp: 0, at: 0)
        try evaluation.record(score: 0.8, captureTimestamp: 1, at: 1)
        evaluation.reject("Poor lighting", at: 1.5)
        try evaluation.record(score: 0.8, captureTimestamp: 2, at: 2)
        #expect(evaluation.snapshot(at: 2).analyze(threshold: 0.7)?.threeConsecutivePasses == false)
        try evaluation.record(score: 0.8, captureTimestamp: 3, at: 3)
        evaluation.breakSequence() // session interruption is not a rejected camera frame
        #expect(evaluation.snapshot(at: 3).currentScore == nil)
        try evaluation.record(score: 0.8, captureTimestamp: 4, at: 4)
        try evaluation.record(score: 0.8, captureTimestamp: 5, at: 7) // >2-second gap
        #expect(evaluation.snapshot(at: 7).analyze(threshold: 0.7)?.threeConsecutivePasses == false)
        try evaluation.record(score: 0.8, captureTimestamp: 6, at: 8)
        try evaluation.record(score: 0.8, captureTimestamp: 7, at: 9)
        let snapshot = evaluation.snapshot(at: 9)
        #expect(snapshot.analyze(threshold: 0.7)?.threeConsecutivePasses == true)
        #expect(snapshot.rejectedReasons["Poor lighting"] == 1 && snapshot.rejectedCount == 1)
    }

    @Test func timeoutFailureAndRetryHaveCleanState() throws {
        var evaluation = RecognitionEvaluation()
        evaluation.begin(at: 10)
        let early = evaluation.expire(at: 54.9)
        let expired = evaluation.expire(at: 55)
        #expect(!early && expired)
        #expect(evaluation.snapshot(at: 100).phase == .timedOut)
        #expect(evaluation.snapshot(at: 100).duration == 45 && evaluation.snapshot(at: 100).statistics == nil)
        evaluation = RecognitionEvaluation()
        #expect(evaluation.snapshot(at: 100).validCount == 0 && evaluation.snapshot(at: 100).rejectedCount == 0)
        #expect(evaluation.phase == .collecting)
        #expect(throws: (any Error).self) { try evaluation.record(score: .nan, captureTimestamp: 0, at: 0) }
        #expect(evaluation.phase == .failed && evaluation.snapshot(at: 0).currentScore == nil)
        var incomplete = RecognitionEvaluation()
        incomplete.finish(.completed, at: 0)
        #expect(incomplete.phase == .failed)
    }
}
