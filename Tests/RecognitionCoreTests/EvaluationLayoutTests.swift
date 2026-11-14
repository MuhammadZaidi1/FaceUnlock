import AppKit
@testable import FaceUnlock
import Foundation
import RecognitionCore
import SwiftUI
import Testing

struct EvaluationLayoutTests {
    @Test @MainActor func evaluationAndResultsFitLightDarkMinimumWidth() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let manager = EnrollmentManager(store: EmptyEvaluationLayoutStore())
        for _ in 0..<100 {
            if !manager.busy { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        var evaluation = RecognitionEvaluation()
        for i in 0..<15 {
            try evaluation.record(score: Double(i)/20, captureTimestamp: Double(i), at: Double(i))
            if i == 6 { evaluation.reject("Synthetic low-quality test frame", at: 6.5) }
        }
        let snapshot = evaluation.snapshot(at: 14)
        for scheme in [ColorScheme.light, .dark] {
            let camera = CameraController()
            camera.report("Evaluation stopped. This is a camera-free layout test; no participant data is used.")
            let root = EvaluationView(camera: camera, manager: manager, retry: {}, close: {})
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            try await inspect(NSHostingView(rootView: root), scheme: scheme, height: 460, name: "evaluation")
            let results = EvaluationResultsView(snapshot: snapshot, customThreshold: 0.65).padding(18).frame(width: 420)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            try await inspect(NSHostingView(rootView: results), scheme: scheme, height: 700, name: "results")
            #expect(!camera.session.isRunning)
        }
    }

    @MainActor private func inspect<V: View>(_ host: NSHostingView<V>, scheme: ColorScheme, height: CGFloat, name: String) async throws {
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 560)
        if let destination = ProcessInfo.processInfo.environment["FACEUNLOCK_EVALUATION_LAYOUT_SNAPSHOTS"] {
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 250_000_000)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
        }
        window.close()
    }
}

private struct EmptyEvaluationLayoutStore: EnrollmentStore {
    func load() throws -> EnrollmentProfile? { nil }
    func save(_ profile: EnrollmentProfile) throws {}
    func delete() throws {}
}
