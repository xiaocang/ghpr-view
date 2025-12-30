import Foundation

enum PRCategory: String, Codable {
    case authored       // PRs created by user
    case reviewRequest  // PRs where user is requested reviewer
}

enum PRState: String, Codable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}

struct PullRequest: Identifiable, Codable, Equatable {
    let id: Int
    let number: Int
    let title: String
    let author: String
    let authorAvatarURL: URL?
    let repositoryOwner: String
    let repositoryName: String
    let url: URL
    let state: PRState
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let reviewThreads: [ReviewThread]
    let category: PRCategory

    var unresolvedCount: Int {
        reviewThreads.filter { !$0.isResolved && !$0.isOutdated }.count
    }

    var repoFullName: String {
        "\(repositoryOwner)/\(repositoryName)"
    }

    static func == (lhs: PullRequest, rhs: PullRequest) -> Bool {
        lhs.id == rhs.id
    }
}
