import AppKit
import SwiftUI

struct EnrollmentView: View {
    @ObservedObject var camera: CameraController
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Face detection setup").font(.title2.weight(.semibold))
            Text("Preview only — identity enrollment is not implemented.")
                .font(.subheadline).foregroundStyle(.secondary)
            CameraPreview(session: camera.session)
                .frame(width: 440, height: 280)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Live camera preview")
            Label(camera.message, systemImage: camera.faceCount > 0 ? "checkmark.circle.fill" : "viewfinder")
                .foregroundStyle(camera.faceCount > 0 ? Color.green : Color.secondary)
                .frame(minHeight: 40, alignment: .leading)
                .accessibilityValue(camera.isStreaming ? "Live detection" : "Camera unavailable or starting")
            Text("Frames are processed locally in memory. Nothing is saved or uploaded. Closing this window stops the camera.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Retry") { camera.start() }
                if camera.permissionDenied {
                    Button("Camera Privacy Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 440)
        .padding(20)
    }
}
