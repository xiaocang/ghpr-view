import Foundation

struct Configuration: Codable, Equatable {
    var githubToken: String
    var username: String
    var refreshInterval: TimeInterval  // seconds, minimum 15
    var repositories: [String]         // ["owner/repo", ...] - empty means all
    var showDrafts: Bool
    var notificationsEnabled: Bool

    static var `default`: Configuration {
        Configuration(
            githubToken: "",
            username: "",
            refreshInterval: 60,
            repositories: [],
            showDrafts: true,
            notificationsEnabled: true
        )
    }

    var isValid: Bool {
        !githubToken.isEmpty && !username.isEmpty && refreshInterval >= 15
    }
}
