import Foundation
import Security

/// Provider-keyed credential store. The production backing is the iOS Keychain
/// (`kSecClassGenericPassword`); the protocol exists so tests and UI tests can
/// swap in an in-memory fake without leaking values into the system keychain.
protocol KeychainStore: AnyObject {
    func getKey(provider: String) -> String
    func setKey(provider: String, key: String)
    func deleteKey(provider: String)
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

    func setKey(provider: String, key: String) {
        let data = Data(key.utf8)
        var attributes = baseQuery(for: provider)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(attributes as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            attributes[kSecValueData as String] = data
            _ = SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    func deleteKey(provider: String) {
        let query = baseQuery(for: provider)
        _ = SecItemDelete(query as CFDictionary)
    }

    func allKeys() -> [String: String] {
        Dictionary(uniqueKeysWithValues: Self.supportedProviders.map { ($0, getKey(provider: $0)) })
    }

    func clear() {
        for provider in Self.supportedProviders {
            deleteKey(provider: provider)
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
    func setKey(provider: String, key: String) { storage[provider] = key }
    func deleteKey(provider: String) { storage.removeValue(forKey: provider) }
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
            if secure.getKey(provider: provider).isEmpty {
                secure.setKey(provider: provider, key: legacyValue)
                migrated = true
            }
            defaults.removeObject(forKey: defaultsKey)
        }
        return migrated
    }
}
