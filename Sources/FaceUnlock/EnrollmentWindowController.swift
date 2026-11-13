import AppKit
import SwiftUI

/// Owns the preview independently of the short-lived menu-bar popover.
@MainActor
final class EnrollmentWindowController: NSObject, NSWindowDelegate {
    private let camera = CameraController()
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 470),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "FaceUnlock Setup"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: EnrollmentView(camera: camera) { [weak self] in
            self?.window?.close()
        })
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        camera.start()
    }

    func windowWillClose(_ notification: Notification) {
        camera.stop(wait: true)
        window = nil
    }

    func shutdown() {
        // Termination waits for queued capture/analysis work and session shutdown.
        camera.stop(wait: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let enrollment = EnrollmentWindowController()

    func applicationWillTerminate(_ notification: Notification) {
        enrollment.shutdown()
    }
}
