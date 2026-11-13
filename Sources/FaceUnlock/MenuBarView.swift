import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
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
                Text("Recognition is not implemented. Your Mac’s authentication is unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Enable Face Recognition", isOn: $appState.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            VStack(spacing: 8) {
                Button { placeholder = .enrollment } label: {
                    Label("Enroll Face…", systemImage: "person.crop.square")
                        .frame(maxWidth: .infinity, alignment: .leading)
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
    case enrollment
    case settings

    var id: String { rawValue }
    var title: String { self == .enrollment ? "Enroll Face" : "Settings" }
    var message: String {
        self == .enrollment
            ? "Face enrollment will be available in a future version. No camera access or biometric data collection occurs."
            : "Settings will be available in a future version. The enable preference is saved automatically."
    }
}
