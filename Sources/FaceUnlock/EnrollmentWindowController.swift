import AppKit
import SwiftUI
import RecognitionCore

/// Owns one temporary window and one capture session for enrollment or verification.
@MainActor
final class EnrollmentWindowController: NSObject, NSWindowDelegate {
    private let camera = CameraController()
    private let manager: EnrollmentManager
    private var poseMode = EnrollmentPoseMode.validated
    private var mode = RecognitionMode.enroll
    private var window: NSWindow?

    init(manager: EnrollmentManager) { self.manager = manager }

    func show() { show(mode: .enroll) }
    func verify() { show(mode: .verify) }

    private func show(mode: RecognitionMode) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard !manager.busy else { return }
        self.mode = mode
        poseMode = .validated
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 80)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = mode == .enroll ? "FaceUnlock Enrollment" : "FaceUnlock Verification"
        window.contentMinSize = NSSize(width: 420, height: 420)
        window.contentMaxSize = NSSize(width: 560, height: 1000)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: EnrollmentView(camera: camera, manager: manager, mode: mode,
            retry: { [weak self] in self?.restart() },
            close: { [weak self] in self?.window?.close() },
            save: { [weak self] in self?.save() },
            useGuidedSamples: { [weak self] in
                self?.poseMode = .guided
                self?.restart()
            }))
        window.center()
        self.window = window
        manager.cameraWindowOpen = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        restart()
    }

    private func restart() {
        guard !manager.busy else { return }
        camera.stop(wait: true)
        if mode == .verify {
            // Re-read for every attempt: a cached profile must not conceal denied,
            // locked, deleted, corrupt, or incompatible Keychain data.
            manager.reload { [weak self] in self?.beginCapture() }
        } else {
            beginCapture()
        }
    }

    private func beginCapture() {
        guard window != nil, !manager.busy else { return }
        if mode == .verify {
            guard let profile = manager.profile, !manager.storageFailed else {
                camera.report(manager.storageFailed ? "Error: \(manager.status)" : "No enrollment. Enroll a face first.")
                return
            }
            do { try profile.validate(for: .sface) }
            catch { camera.report(error.localizedDescription); return }
            guard manager.permitVerification() else {
                camera.report("Retry delay active. Wait at least 5 seconds; at most 3 attempts per minute.")
                return
            }
        }
        let pipeline = RecognitionPipeline(mode: mode, profile: manager.profile, poseMode: poseMode)
        camera.start(pipeline: pipeline, timeout: mode == .verify ? 20 : 90)
    }

    private func save() {
        guard let candidate = camera.candidate else { return }
        manager.save(candidate) { [weak self] success in
            if success { self?.window?.close() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !manager.busy }

    func windowWillClose(_ notification: Notification) {
        camera.stop(wait: true)
        if mode == .verify { manager.finishVerification() }
        manager.cameraWindowOpen = false
        window = nil
    }

    func shutdown() { camera.stop(wait: true) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let enrollmentManager = EnrollmentManager()
    lazy var enrollment = EnrollmentWindowController(manager: enrollmentManager)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        enrollment.shutdown()
        // Keychain operations are atomic. Let an explicitly requested save/delete finish before exit.
        if enrollmentManager.busy {
            Task { @MainActor in
                while enrollmentManager.busy { try? await Task.sleep(nanoseconds: 100_000_000) }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { enrollment.shutdown() }
}
