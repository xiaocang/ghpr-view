import Foundation
import Security

enum KeychainError: Error {
    case duplicateItem
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case invalidData
}

// Type alias for backward compatibility
typealias KeychainHelper = Keychain

final class Keychain {
    static let shared = Keychain()

    private let service = "com.xiaocang.PRDashboard"
    private let tokenKey = "github_token"
    private let usernameKey = "github_username"
    private let authMethodKey = "github_auth_method"

    private init() {}

    // MARK: - Token

    func saveToken(_ token: String) throws {
        try save(value: token, key: tokenKey)
    }

    func loadToken() throws -> String {
        try load(key: tokenKey)
    }

    func deleteToken() throws {
        try delete(key: tokenKey)
    }

    // MARK: - Username

    func saveUsername(_ username: String) throws {
        try save(value: username, key: usernameKey)
    }

    func loadUsername() throws -> String {
        try load(key: usernameKey)
    }

    func deleteUsername() throws {
        try delete(key: usernameKey)
    }

    // MARK: - Auth Method

    func saveAuthMethod(_ method: AuthMethod) throws {
        try save(value: method.rawValue, key: authMethodKey)
    }

    func loadAuthMethod() throws -> AuthMethod {
        let value = try load(key: authMethodKey)
        guard let method = AuthMethod(rawValue: value) else {
            throw KeychainError.invalidData
        }
        return method
    }

    func deleteAuthMethod() throws {
        try delete(key: authMethodKey)
    }

    // MARK: - AuthState

    static func saveAuthState(_ state: AuthState) throws {
        if let token = state.accessToken {
            try shared.saveToken(token)
        } else {
            try? shared.deleteToken()
        }
        if let username = state.username {
            try shared.saveUsername(username)
        } else {
            try? shared.deleteUsername()
        }
        if let method = state.authMethod {
            try shared.saveAuthMethod(method)
        } else {
            try? shared.deleteAuthMethod()
        }
    }

    static func loadAuthState() -> AuthState {
        let token = try? shared.loadToken()
        let username = try? shared.loadUsername()
        let authMethod = try? shared.loadAuthMethod()
        return AuthState(accessToken: token, username: username, authMethod: authMethod)
    }

    static func deleteAuthState() {
        try? shared.deleteToken()
        try? shared.deleteUsername()
        try? shared.deleteAuthMethod()
    }

    // MARK: - Private

    private func save(value: String, key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // Delete existing item first
        try? delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            if status == errSecDuplicateItem {
                throw KeychainError.duplicateItem
            }
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func load(key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return value
    }

    private func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
