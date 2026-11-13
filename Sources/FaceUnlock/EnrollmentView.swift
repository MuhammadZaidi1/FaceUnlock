import AppKit
import SwiftUI
import RecognitionCore

struct EnrollmentView: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var manager: EnrollmentManager
    let mode: RecognitionMode
    let retry: () -> Void
    let close: () -> Void
    let save: () -> Void
    let useGuidedSamples: () -> Void
    @State private var confirmGuided = false
    var recognitionDeveloperDiagnostics = CommandLine.arguments.contains("--recognition-diagnostics")
    var developerDiagnostics = CommandLine.arguments.contains("--enrollment-diagnostics")

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    wrapped(mode == .enroll ? "Enroll your face" : "Verify your face").font(.title2.weight(.semibold))
                    wrapped("Prototype only · No reliable anti-spoofing · Not for authentication")
                        .font(.caption).foregroundStyle(.secondary)
                    CameraPreview(session: camera.session)
                        .frame(maxWidth: .infinity).frame(height: 220)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(camera.completed ? "Camera stopped" : "Live camera preview")
                        .overlay {
                            if camera.completed { Text("Camera stopped").padding(8).background(.black.opacity(0.8)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 6)) }
                        }
                    if mode == .enroll, let diagnostics = camera.diagnostics {
                        ProgressView(value: Double(diagnostics.accepted), total: 6) {
                            wrapped("\(diagnostics.accepted) of 6 samples · \(diagnostics.stage)")
                        }
                        if diagnostics.poseMode == .guided {
                            wrapped("Guided samples: head turns are NOT validated.")
                                .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                        }
                    }
                    if mode == .verify {
                        wrapped("Identity acceptance disabled: confirmed false acceptance is under investigation.")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                        if camera.completed {
                            wrapped("Completed attempt — camera is off. This result does not apply to a new person. Retry starts a new comparison.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    wrapped(manager.busy ? "Accessing local Keychain…" : camera.message)
                        .font(.subheadline)
                        .accessibilityLabel("Recognition status: \(camera.message)")
                    if manager.storageFailed {
                        wrapped(manager.status).font(.caption).foregroundStyle(.red)
                    }
                    if mode == .enroll, let diagnostics = camera.diagnostics,
                       diagnostics.canOfferGuided, diagnostics.poseMode == .validated, !camera.completed {
                        Button("Use guided samples with unvalidated turns…") { confirmGuided = true }
                            .font(.caption)
                    }
                    wrapped(mode == .enroll
                         ? "Collect six quality samples. Save only when complete. Cancel preserves your previous enrollment."
                         : "Photos or screens may fool this prototype. A match does not unlock your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    wrapped("Processing stays local. Only the saved enrollment embedding is kept in Keychain. Closing stops the camera.")
                        .font(.caption).foregroundStyle(.secondary)
                    if recognitionDeveloperDiagnostics && mode == .verify {
                        DisclosureGroup("Recognition diagnostics — not identity probabilities") {
                            if let diagnostics = camera.recognitionDiagnostics {
                                RecognitionDiagnosticsView(diagnostics: diagnostics, captureActive: camera.isStreaming)
                            } else { wrapped("No frame evaluated in this attempt. Prior scores are cleared on Retry.") }
                        }.font(.caption)
                    }
                    if developerDiagnostics && mode == .enroll {
                        DisclosureGroup("Developer diagnostics — transient, not logged") {
                            diagnosticDetails
                        }.font(.caption)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if camera.permissionDenied {
                    Button("Camera Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                HStack {
                    Button("Retry", action: retry).disabled(manager.busy)
                    Spacer(minLength: 8)
                    if mode == .enroll, camera.candidate != nil {
                        Button(manager.busy ? "Saving…" : "Save Enrollment", action: save)
                            .disabled(manager.busy).keyboardShortcut(.defaultAction)
                    }
                    Button(mode == .enroll ? "Cancel" : "Done", action: close).disabled(manager.busy)
                }
            }.padding(14)
        }
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 560, minHeight: 420, idealHeight: 620, maxHeight: .infinity)
        .confirmationDialog("Use samples without validated head turns?", isPresented: $confirmGuided, titleVisibility: .visible) {
            Button("Restart with guided samples", action: useGuidedSamples)
            Button("Keep validating turns", role: .cancel) {}
        } message: {
            Text("This restarts all six samples. Vary your pose naturally; this mode does not verify head turns. Face quality, alignment, lighting, blur, and real identity checks remain required. Your saved enrollment is unchanged until Save.")
        }
        .onChange(of: camera.completed) { completed in
            if completed && mode == .verify { manager.finishVerification() }
        }
    }

    private func wrapped(_ text: String) -> some View {
        Text(text).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var diagnosticDetails: some View {
        if let d = camera.diagnostics {
            VStack(alignment: .leading, spacing: 6) {
                wrapped("Stage: \(d.stage) · accepted \(d.accepted)/6")
                wrapped("Yaw: \(angle(d.pose.yaw)) · pitch: \(angle(d.pose.pitch)) · roll: \(angle(d.pose.roll))")
                wrapped("Expected yaw: \(d.expected)")
                wrapped("Latest rejection: \(d.rejection ?? "None — sample accepted or checking")")
                wrapped("Capture quality: \(number(d.captureQuality.map(Double.init))) (minimum 0.40) · face: \(d.facePixels)")
                wrapped("Alignment RMS: \(number(d.modelQuality?.alignmentResidual)) px (max 5)")
                wrapped("Luminance: \(number(d.modelQuality?.meanLuminance)) · clipped fraction: \(number(d.modelQuality?.clippedFraction))")
                wrapped("Blur variance: \(number(d.modelQuality?.laplacianVariance)) (minimum 70)")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    wrapped("Processed frames: \(d.processedFrames) · last \(String(format: "%.1f", max(0, ProcessInfo.processInfo.systemUptime - d.processedAt)))s ago · \(camera.isStreaming ? "capture active" : "capture stopped")")
                }
                wrapped("Unmirrored inference · mirrored preview · radians converted to degrees above. ‘—’ means unavailable/not evaluated this frame.")
            }.padding(.top, 8).textSelection(.disabled)
        } else { wrapped("Waiting for an analyzed camera frame.") }
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }
    private func angle(_ value: Double?) -> String { value.map { String(format: "%.2f°", FacePose.degrees($0)) } ?? "— (unavailable)" }
}
