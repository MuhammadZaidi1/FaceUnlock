import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "faceRecognitionEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    var status: String {
        isEnabled ? "Enabled · Preview only" : "Disabled"
    }
}
