import Foundation
import Combine

final class ConfigurationStore: ObservableObject {
    @Published private(set) var configuration: Configuration

    private let userDefaults: UserDefaults
    private let keychain: Keychain

    private enum Keys {
        static let username = "github_username"
        static let refreshInterval = "refresh_interval"
        static let repositories = "repositories"
        static let showDrafts = "show_drafts"
        static let notificationsEnabled = "notifications_enabled"
    }

    init(userDefaults: UserDefaults = .standard, keychain: Keychain = .shared) {
        self.userDefaults = userDefaults
        self.keychain = keychain
        self.configuration = Configuration.default

        load()
    }

    func load() {
        var config = Configuration.default

        // Load token from Keychain
        if let token = try? keychain.loadToken() {
            config.githubToken = token
        }

        // Load other settings from UserDefaults
        if let username = userDefaults.string(forKey: Keys.username) {
            config.username = username
        }

        let refreshInterval = userDefaults.double(forKey: Keys.refreshInterval)
        if refreshInterval >= 15 {
            config.refreshInterval = refreshInterval
        }

        if let repos = userDefaults.stringArray(forKey: Keys.repositories) {
            config.repositories = repos
        }

        if userDefaults.object(forKey: Keys.showDrafts) != nil {
            config.showDrafts = userDefaults.bool(forKey: Keys.showDrafts)
        }

        if userDefaults.object(forKey: Keys.notificationsEnabled) != nil {
            config.notificationsEnabled = userDefaults.bool(forKey: Keys.notificationsEnabled)
        }

        self.configuration = config
    }

    func save(_ config: Configuration) throws {
        // Validate
        guard config.refreshInterval >= 15 else {
            throw ConfigurationError.invalidRefreshInterval
        }

        // Save token to Keychain
        if !config.githubToken.isEmpty {
            try keychain.saveToken(config.githubToken)
        } else {
            try? keychain.deleteToken()
        }

        // Save other settings to UserDefaults
        userDefaults.set(config.username, forKey: Keys.username)
        userDefaults.set(config.refreshInterval, forKey: Keys.refreshInterval)
        userDefaults.set(config.repositories, forKey: Keys.repositories)
        userDefaults.set(config.showDrafts, forKey: Keys.showDrafts)
        userDefaults.set(config.notificationsEnabled, forKey: Keys.notificationsEnabled)

        self.configuration = config
    }
}

enum ConfigurationError: LocalizedError {
    case invalidRefreshInterval

    var errorDescription: String? {
        switch self {
        case .invalidRefreshInterval:
            return "Refresh interval must be at least 15 seconds"
        }
    }
}
