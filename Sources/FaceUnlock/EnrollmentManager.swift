import Combine
import Foundation
import RecognitionCore

@MainActor
final class EnrollmentManager: ObservableObject {
    @Published private(set) var profile: EnrollmentProfile?
    @Published private(set) var status = "Loading enrollment…"
    @Published private(set) var busy = false
    @Published private(set) var storageFailed = false
    @Published var cameraWindowOpen = false
    private let store: EnrollmentStore
    private let queue = DispatchQueue(label: "com.faceunlock.keychain", qos: .userInitiated)
    private var limiter = AttemptLimiter()

    init(store: EnrollmentStore = KeychainEnrollmentStore()) {
        self.store = store
        reload()
    }

    func reload(completion: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        let store = store
        queue.async {
            let result = Result { () -> EnrollmentProfile? in
                let profile = try store.load()
                try profile?.validate(for: .sface)
                return profile
            }
            DispatchQueue.main.async {
                self.finish(result)
                completion?()
            }
        }
    }

    func save(_ candidate: EnrollmentProfile, completion: @escaping (Bool) -> Void) {
        guard !busy else { return }
        busy = true
        let store = store
        queue.async {
            let result = Result { () -> EnrollmentProfile? in
                try candidate.validate(for: .sface)
                try store.save(candidate)
                return candidate
            }
            DispatchQueue.main.async {
                self.finish(result)
                if case .success = result { completion(true) } else { completion(false) }
            }
        }
    }

    func delete() {
        guard !busy else { return }
        busy = true
        let store = store
        queue.async {
            let result = Result { () -> EnrollmentProfile? in
                try store.delete()
                return nil
            }
            DispatchQueue.main.async { self.finish(result) }
        }
    }

    func finishVerification() { limiter.finish(at: ProcessInfo.processInfo.systemUptime) }

    func permitVerification() -> Bool {
        limiter.begin(at: ProcessInfo.processInfo.systemUptime)
    }

    private func finish(_ result: Result<EnrollmentProfile?, Error>) {
        busy = false
        switch result {
        case .success(let profile):
            self.profile = profile
            status = profile == nil ? "Not Enrolled" : "Enrolled"
            storageFailed = false
        case .failure(let error):
            // Keep a valid in-memory old profile, but block verification until storage is readable.
            status = error.localizedDescription
            storageFailed = true
        }
    }
}
