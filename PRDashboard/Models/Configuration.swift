import Foundation

struct Configuration: Codable, Equatable {
    var refreshInterval: TimeInterval  // seconds, minimum 15
    var repositories: [String]         // ["owner/repo", ...] - empty means all
    var showDrafts: Bool
    var notificationsEnabled: Bool

    static var `default`: Configuration {
        Configuration(
            refreshInterval: 60,
            repositories: [],
            showDrafts: true,
            notificationsEnabled: true
        )
    }

    var isValid: Bool {
        refreshInterval >= 15
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

// OAuth tokens stored separately in Keychain
struct AuthState: Codable, Equatable {
    var accessToken: String?
    var username: String?

    var isAuthenticated: Bool {
        accessToken != nil
    }

    static var empty: AuthState {
        AuthState(accessToken: nil, username: nil)
    }
}
