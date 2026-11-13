import SwiftUI

@main
struct FaceUnlockApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("FaceUnlock", systemImage: "faceid") {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
