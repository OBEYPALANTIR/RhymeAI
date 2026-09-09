import Foundation
import Security

/// Provider-keyed credential store. The production backing is the iOS Keychain
/// (`kSecClassGenericPassword`); the protocol exists so tests and UI tests can
/// swap in an in-memory fake without leaking values into the system keychain.
protocol KeychainStore: AnyObject {
    func getKey(provider: String) -> String
    /// Returns false when the backing store rejected the write (e.g. keychain
    /// unavailable) so callers can tell the user instead of silently losing the key.
    @discardableResult
    func setKey(provider: String, key: String) -> Bool
    @discardableResult
    func deleteKey(provider: String) -> Bool
    func allKeys() -> [String: String]
    func clear()
}

extension KeychainStore {
    static var supportedProviders: [String] {
        AIProvider.allCases
            .filter { $0 != .local }
            .map { $0.rawValue }
    }
}

final class SystemKeychainStore: KeychainStore {
    private let service: String

    init(service: String = "ShaydeTree.Writers-Block.apiKeys") {
        self.service = service
    }

    func getKey(provider: String) -> String {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    @discardableResult
    func setKey(provider: String, key: String) -> Bool {
        let data = Data(key.utf8)
        var attributes = baseQuery(for: provider)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(attributes as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        guard updateStatus == errSecItemNotFound else { return false }
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func deleteKey(provider: String) -> Bool {
        let query = baseQuery(for: provider)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func allKeys() -> [String: String] {
        Dictionary(uniqueKeysWithValues: Self.supportedProviders.map { ($0, getKey(provider: $0)) })
    }

    func clear() {
        for provider in Self.supportedProviders {
            _ = deleteKey(provider: provider)
        }
    }

    private func baseQuery(for provider: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider
        ]
    }
}

/// In-memory store. Used for unit tests and UI tests that should not touch the
/// real keychain.
final class InMemoryKeychainStore: KeychainStore {
    private var storage: [String: String] = [:]

    func getKey(provider: String) -> String { storage[provider] ?? "" }
    @discardableResult
    func setKey(provider: String, key: String) -> Bool {
        storage[provider] = key
        return true
    }
    @discardableResult
    func deleteKey(provider: String) -> Bool {
        storage.removeValue(forKey: provider)
        return true
    }
    func allKeys() -> [String: String] {
        Dictionary(uniqueKeysWithValues: Self.supportedProviders.map { ($0, storage[$0] ?? "") })
    }
    func clear() { storage.removeAll() }
}

/// One-shot migration of plaintext API keys out of `UserDefaults` into the
/// secure store. Pure function so it is unit-testable with `InMemoryKeychainStore`
/// and an injected defaults instance. Returns true iff at least one key moved.
enum ApiKeyMigration {
    static func apply(
        legacyDefaults defaults: UserDefaults,
        secure: KeychainStore,
        providers: [String] = SystemKeychainStore.supportedProviders,
        defaultsKeyPrefix: String = "apiKey_"
    ) -> Bool {
        var migrated = false
        for provider in providers {
            let defaultsKey = "\(defaultsKeyPrefix)\(provider)"
            guard let legacyValue = defaults.string(forKey: defaultsKey),
                  !legacyValue.isEmpty else {
                continue
            }
            if !secure.getKey(provider: provider).isEmpty {
                defaults.removeObject(forKey: defaultsKey)
                continue
            }
            guard secure.setKey(provider: provider, key: legacyValue) else { continue }
            defaults.removeObject(forKey: defaultsKey)
            migrated = true
        }
        return migrated
    }
}
