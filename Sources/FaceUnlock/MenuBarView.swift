import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var enrollment: EnrollmentManager
    let verify: () -> Void
    let openEnrollment: () -> Void
    let evaluate: () -> Void
    @State private var confirmDeletion = false
    @State private var placeholder: Placeholder?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("FaceUnlock", systemImage: "faceid")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Face Recognition")
                    .font(.subheadline.weight(.medium))
                Label(appState.status, systemImage: appState.isEnabled ? "circle.dotted" : "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(enrollment.status).font(.caption)
                Text("Identity acceptance disabled after false acceptance. Diagnostic comparison only. Does not unlock your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Enable (preference only)", isOn: $appState.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            VStack(spacing: 8) {
                Button(action: openEnrollment) {
                    Label(enrollment.profile == nil ? "Enroll Face…" : "Replace Face…", systemImage: "person.crop.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(enrollment.busy)
                Button(action: verify) {
                    Label("Verify Face…", systemImage: "person.badge.shield.checkmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(enrollment.busy || enrollment.cameraWindowOpen)
                if DeveloperFeatures.recognitionEvaluation {
                    Button(action: evaluate) {
                        Label("Evaluate Recognition…", systemImage: "chart.bar")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(enrollment.busy || enrollment.cameraWindowOpen)
                }
                Button(role: .destructive) { confirmDeletion = true } label: {
                    Label("Delete Enrollment…", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(enrollment.busy || enrollment.cameraWindowOpen || (enrollment.profile == nil && !enrollment.storageFailed))
                if enrollment.storageFailed {
                    Button("Retry Enrollment Access") { enrollment.reload() }
                        .disabled(enrollment.busy || enrollment.cameraWindowOpen)
                }
                Button { placeholder = .settings } label: {
                    Label("Settings…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Button("Quit FaceUnlock") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(18)
        .frame(width: 300)
        .confirmationDialog("Delete local enrollment?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete Enrollment", role: .destructive) { enrollment.delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the FaceUnlock Keychain record. You will need to enroll again.")
        }
        .alert(item: $placeholder) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private enum Placeholder: String, Identifiable {
    case settings

    var id: String { rawValue }
    var title: String { "Settings" }
    var message: String {
        "Settings will be available in a future version. The enable preference is saved automatically."
    }
}
