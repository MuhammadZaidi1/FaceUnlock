import AppKit
import SwiftUI

struct EnrollmentView: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var manager: EnrollmentManager
    let mode: RecognitionMode
    let retry: () -> Void
    let close: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .enroll ? "Enroll your face" : "Verify your face").font(.title2.weight(.semibold))
            Text("Prototype only · No reliable anti-spoofing · Not for authentication")
                .font(.caption).foregroundStyle(.secondary)
            CameraPreview(session: camera.session)
                .frame(width: 440, height: 280)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Live camera preview")
            Text(manager.busy ? "Accessing local Keychain…" : camera.message)
                .font(.subheadline)
                .frame(minHeight: 48, alignment: .leading)
                .accessibilityLabel("Recognition status: \(camera.message)")
            if manager.storageFailed {
                Text(manager.status).font(.caption).foregroundStyle(.red)
            }
            Text(mode == .enroll
                 ? "Collect 6 samples: front, slight turn, opposite turn. Save only when complete. Cancel preserves your previous enrollment."
                 : "Requires several matching frames. Photos or screens may fool this prototype; a match does not unlock your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Text("All processing is local. Only the saved enrollment embedding is kept in Keychain. Closing stops the camera.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Retry", action: retry).disabled(manager.busy)
                if camera.permissionDenied {
                    Button("Camera Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Spacer()
                if mode == .enroll, camera.candidate != nil {
                    Button(manager.busy ? "Saving…" : "Save Enrollment", action: save)
                        .disabled(manager.busy)
                        .keyboardShortcut(.defaultAction)
                }
                Button(mode == .enroll ? "Cancel" : "Done", action: close).disabled(manager.busy)
            }
        }
        .frame(width: 440)
        .padding(20)
        .onChange(of: camera.completed) { completed in
            if completed && mode == .verify { manager.finishVerification() }
        }
    }
}
