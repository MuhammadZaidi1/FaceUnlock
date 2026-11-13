import SwiftUI

struct RecognitionDiagnosticsView: View {
    let diagnostics: RecognitionDiagnostics
    let captureActive: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Cosine similarity: \(diagnostics.score.map { String(format: "%.6f", $0) } ?? "— not evaluated")")
            row("Threshold: \(String(format: "%.6f", diagnostics.threshold)) · passed: \(diagnostics.passedThreshold.map { $0 ? "Yes" : "No" } ?? "—")")
            row("Consecutive threshold passes: \(diagnostics.streak)/3 · evaluated frames: \(diagnostics.evaluatedFrames)")
            row("Last processed frame fresh: \(diagnostics.freshFrame ? "Yes" : "No — repeated or retained terminal result")")
            row("Capture now: \(captureActive ? "Active" : "Stopped — snapshot is not a live comparison")")
            row("Capture timestamp: \(diagnostics.frameTimestamp.map { String(format: "%.3f", $0) } ?? "—") · monotonic capture time, not wall clock")
            row("Rejection/error: \(diagnostics.rejection ?? "None for this frame")")
            row("Model: \(diagnostics.model.name) · preprocessing v\(diagnostics.model.pipelineVersion)")
            row("Scores are NOT identity probabilities. Positive identity acceptance is disabled following a confirmed false acceptance. Three passes end as Inconclusive.")
        }.font(.caption).padding(.top, 8)
    }
    private func row(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
