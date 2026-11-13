import SwiftUI

@main
struct FaceUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("FaceUnlock", systemImage: "faceid") {
            MenuBarView(appState: appState, openEnrollment: delegate.enrollment.show)
        }
        .menuBarExtraStyle(.window)
    }
}
