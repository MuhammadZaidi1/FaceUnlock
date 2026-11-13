import Foundation
import Security

/// One non-synchronizing generic-password item in the user's local login Keychain.
/// No custom ACL granting arbitrary apps, no UserDefaults or on-disk plaintext copies.
public struct KeychainEnrollmentStore: EnrollmentStore {
    private let service: String
    public init(service: String = "com.faceunlock.app.enrollment.v1") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "single-identity",
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: false]
    }

    public func load() throws -> EnrollmentProfile? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RecognitionError.storage(status) }
        guard let data = result as? Data, data.count <= 32_768,
              let profile = try? JSONDecoder().decode(EnrollmentProfile.self, from: data) else {
            throw RecognitionError.corruptProfile
        }
        return profile
    }

    public func save(_ profile: EnrollmentProfile) throws {
        try profile.validate(for: .sface)
        let data = try JSONEncoder().encode(profile)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "FaceUnlock local face enrollment"
            // Classic macOS login Keychain: accessibility classes require the data-protection
            // Keychain and are intentionally not claimed for this ad-hoc-signed prototype.
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw RecognitionError.storage(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RecognitionError.storage(status)
        }
    }
}
