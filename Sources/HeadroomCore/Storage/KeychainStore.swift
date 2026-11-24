import Foundation
import Security
import LocalAuthentication

public enum CredentialKind: String, Codable, CaseIterable, Sendable {
    case sessionCookie = "cookie"
    case oauthToken = "token"
    case apiKey = "apikey"
}

public protocol SecretStore: Sendable {
    func getSecret(provider: ProviderID, accountLabel: String, kind: CredentialKind) -> String?
    func setSecret(_ value: String, provider: ProviderID, accountLabel: String, kind: CredentialKind) throws
    func deleteSecret(provider: ProviderID, accountLabel: String, kind: CredentialKind) throws
}

public enum KeychainError: Error, LocalizedError, Sendable {
    case encodingFailed
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode credential as UTF-8."
        case .osStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(message)"
            }
            return "Keychain error (\(status))."
        }
    }
}

/// Native macOS Keychain storage for opt-in session cookies, OAuth tokens, and API keys.
/// Never stores raw provider passwords.
public final class KeychainStore: SecretStore, Sendable {
    private let service: String

    public init(service: String = "com.headroom.credentials") {
        self.service = service
    }

    private func accountKey(provider: ProviderID, accountLabel: String, kind: CredentialKind) -> String {
        "\(provider.rawValue):\(accountLabel):\(kind.rawValue)"
    }

    public func getSecret(provider: ProviderID, accountLabel: String, kind: CredentialKind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(provider: provider, accountLabel: accountLabel, kind: kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String, provider: ProviderID, accountLabel: String, kind: CredentialKind) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let account = accountKey(provider: provider, accountLabel: accountLabel, kind: kind)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    public func deleteSecret(provider: ProviderID, accountLabel: String, kind: CredentialKind) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(provider: provider, accountLabel: accountLabel, kind: kind)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    /// Reads an external macOS Keychain generic password item (e.g. Claude Code CLI credentials)
    /// without ever blocking on an interactive macOS Keychain modal prompt.
    public func readExternalGenericPassword(service externalService: String, account: String? = nil) -> String? {
        let laContext = LAContext()
        laContext.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: externalService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: laContext
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Thread-safe in-memory secret store for tests and ephemeral runs.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(initial: [String: String] = [:]) {
        self.storage = initial
    }

    private func key(_ provider: ProviderID, _ label: String, _ kind: CredentialKind) -> String {
        "\(provider.rawValue):\(label):\(kind.rawValue)"
    }

    public func getSecret(provider: ProviderID, accountLabel: String, kind: CredentialKind) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(provider, accountLabel, kind)]
    }

    public func setSecret(_ value: String, provider: ProviderID, accountLabel: String, kind: CredentialKind) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key(provider, accountLabel, kind)] = value
    }

    public func deleteSecret(provider: ProviderID, accountLabel: String, kind: CredentialKind) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key(provider, accountLabel, kind))
    }
}
