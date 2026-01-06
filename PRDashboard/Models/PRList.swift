import Foundation

struct PRList {
    var lastUpdated: Date
    var pullRequests: [PullRequest]
    var isLoading: Bool
    var error: Error?

    var totalUnresolvedCount: Int {
        pullRequests.reduce(0) { $0 + $1.unresolvedCount }
    }

    /// Unresolved comment count for authored PRs only (used for menu bar badge)
    var authoredUnresolvedCount: Int {
        authoredPRs.reduce(0) { $0 + $1.unresolvedCount }
    }

    var authoredPRs: [PullRequest] {
        pullRequests.filter { $0.category == .authored }
    }

    var reviewRequestPRs: [PullRequest] {
        pullRequests.filter { $0.category == .reviewRequest }
    }

    static var empty: PRList {
        PRList(lastUpdated: Date(), pullRequests: [], isLoading: false, error: nil)
    }
}

struct IdentifiableError: Identifiable {
    let id = UUID()
    let error: Error

    var localizedDescription: String {
        error.localizedDescription
    }
}
