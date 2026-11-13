import AppKit
@testable import FaceUnlock
import Foundation
import RecognitionCore
import SwiftUI
import Testing

struct EnrollmentLayoutTests {
    @Test @MainActor func lightAndDarkMinimumWindowLayouts() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let manager = EnrollmentManager(store: EmptyLayoutStore())
        for _ in 0..<100 {
            if !manager.busy { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        for scheme in [ColorScheme.light, .dark] {
            let camera = CameraController()
            camera.report("2 of 6 samples · Head-turn estimate unavailable. Retry, or explicitly choose guided samples with unvalidated turns. Your previous enrollment is unchanged until Save.")
            let root = EnrollmentView(camera: camera, manager: manager, mode: .enroll,
                retry: {}, close: {}, save: {}, useGuidedSamples: {}, developerDiagnostics: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 460)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= 560)
            #expect(!camera.session.isRunning)
            if let destination = ProcessInfo.processInfo.environment["FACEUNLOCK_LAYOUT_SNAPSHOTS"] {
                window.orderFrontRegardless()
                try await Task.sleep(nanoseconds: 250_000_000)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(scheme == .light ? "light.png" : "dark.png"))
            }
            window.close()
        }
    }
}

private struct EmptyLayoutStore: EnrollmentStore {
    func load() throws -> EnrollmentProfile? { nil }
    func save(_ profile: EnrollmentProfile) throws {}
    func delete() throws {}
}
