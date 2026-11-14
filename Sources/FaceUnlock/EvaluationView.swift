import AppKit
import RecognitionCore
import SwiftUI

struct EvaluationView: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var manager: EnrollmentManager
    let retry: () -> Void
    let close: () -> Void
    @State private var label = ""
    @State private var thresholdText = ""
    @State private var customThreshold: Double?
    @State private var thresholdError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    wrapped("Recognition evaluation").font(.title2.weight(.semibold))
                    wrapped("Experimental — not an authentication decision")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                    wrapped("One consenting person per attempt. This does not establish identity or ground truth.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Optional test label (this window only)", text: $label)
                        .textFieldStyle(.roundedBorder)
                    CameraPreview(session: camera.session)
                        .frame(maxWidth: .infinity).frame(height: 220)
                        .background(.black).clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(camera.completed ? "Camera stopped" : "Live evaluation preview")
                        .overlay {
                            if camera.completed { Text("Camera stopped").padding(8).background(.black.opacity(0.8)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 6)) }
                        }
                    ProgressView(value: Double(camera.evaluation?.validCount ?? 0), total: 15) {
                        wrapped("\(camera.evaluation?.validCount ?? 0)/15 valid comparisons")
                    }
                    wrapped(manager.busy ? "Reading local Keychain…" : camera.message)
                    if manager.storageFailed { wrapped(manager.status).foregroundStyle(.red) }
                    wrapped("Latest comparison cosine: \(camera.evaluation?.currentScore.map { String(format: "%.6f", $0) } ?? "— not evaluated or frame rejected")")
                        .monospacedDigit()
                    wrapped("Scores are not identity probabilities. Camera use is limited to 45 seconds. Retry clears results, label, and custom threshold.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let snapshot = camera.evaluation {
                        EvaluationResultsView(snapshot: snapshot, customThreshold: customThreshold)
                    }
                    Divider()
                    wrapped("Inspect another experimental threshold (−1…1)").font(.subheadline)
                    HStack {
                        TextField("For example 0.65", text: $thresholdText).textFieldStyle(.roundedBorder)
                            .onSubmit(inspectThreshold)
                        Button("Inspect", action: inspectThreshold)
                    }
                    if let thresholdError { wrapped(thresholdError).font(.caption).foregroundStyle(.red) }
                    wrapped("These controls only recompute this attempt's in-memory analysis. Production verification stays at 0.363 and remains Inconclusive on threshold passes. No result is saved, exported, uploaded, or logged.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Cancel", action: close)
                Button("Retry") {
                    label = ""; thresholdText = ""; customThreshold = nil; thresholdError = nil
                    retry()
                }.disabled(manager.busy)
                Spacer(minLength: 8)
                if camera.permissionDenied {
                    Button("Camera Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
                    }
                }
                Button("Done", action: close)
            }.padding(14)
        }
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 560, minHeight: 420, idealHeight: 640, maxHeight: .infinity)
    }

    private func inspectThreshold() {
        guard let value = Double(thresholdText.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, (-1...1).contains(value) else {
            thresholdError = "Enter a finite value from −1 through 1 using a decimal point."
            return
        }
        customThreshold = value; thresholdError = nil
    }
    private func wrapped(_ value: String) -> some View {
        Text(value).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EvaluationResultsView: View {
    let snapshot: EvaluationSnapshot
    let customThreshold: Double?
    private var thresholds: [Double] {
        Array(Set(EvaluationSnapshot.candidateThresholds + (customThreshold.map { [$0] } ?? []))).sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            wrapped(snapshot.phase == .completed ? "Completed evaluation statistics" : (snapshot.phase == .collecting ? "Running statistics — incomplete" : "Partial statistics — evaluation did not complete"))
                .font(.headline)
            wrapped("Valid: \(snapshot.validCount)/15 · rejected analyzed frames: \(snapshot.rejectedCount) · duration: \(String(format: "%.1f", snapshot.duration)) s")
            if let stats = snapshot.statistics {
                wrapped("Min \(number(stats.minimum)) · max \(number(stats.maximum))")
                wrapped("Mean \(number(stats.mean)) · median \(number(stats.median))")
                wrapped("Population standard deviation \(number(stats.standardDeviation))")
            } else { wrapped("No valid comparisons; similarity statistics unavailable.") }
            if !snapshot.rejectedReasons.isEmpty {
                DisclosureGroup("Rejected-frame reasons (\(snapshot.rejectedCount))") {
                    ForEach(snapshot.rejectedReasons.keys.sorted(), id: \.self) { reason in
                        wrapped("\(snapshot.rejectedReasons[reason] ?? 0) × \(reason)").font(.caption)
                    }
                }
            }
            wrapped("Experimental — not an authentication decision").font(.subheadline.weight(.medium)).foregroundStyle(.orange)
            ForEach(thresholds, id: \.self) { threshold in
                if let analysis = snapshot.analyze(threshold: threshold) {
                    VStack(alignment: .leading, spacing: 3) {
                        wrapped("Threshold \(String(threshold))\(threshold == 0.363 ? " (current policy value)" : " (experimental)")").font(.subheadline.weight(.medium))
                        wrapped("\(analysis.passingCount)/\(snapshot.validCount) passing (\(snapshot.validCount == 0 ? "—" : String(format: "%.1f%%", analysis.passingPercentage))) · three consecutive: \(analysis.threeConsecutivePasses ? "Yes" : "No")").font(.caption)
                    }
                }
            }
            wrapped("Rejections, capture interruptions and gaps longer than 2 s break the simulated streak. Passing-frame percentages are not accuracy, identity confidence, or false-accept rates.")
                .font(.caption).foregroundStyle(.secondary)
        }.monospacedDigit().frame(maxWidth: 560, alignment: .leading)
    }
    private func number(_ value: Double) -> String { String(format: "%.6f", value) }
    private func wrapped(_ value: String) -> some View {
        Text(value).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
