import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case rateLimited(resetDate: Date)
    case network(Error)
    case decoding(Error)
    case invalidResponse
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Invalid GitHub token. Please check your settings."
        case .rateLimited(let resetDate):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Rate limited. Try again after \(formatter.string(from: resetDate))"
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from GitHub"
        case .unknown(let message):
            return message
        }
    }
}

final class GitHubAPIClient {
    private let graphQLURL = URL(string: "https://api.github.com/graphql")!
    private var token: String
    private let session: URLSession
    private var lastETag: String?

    init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func updateToken(_ newToken: String) {
        self.token = newToken
    }

    func fetchPullRequests(username: String, category: PRCategory) async throws -> [PullRequest] {
        let searchQuery: String
        switch category {
        case .authored:
            searchQuery = "is:pr is:open author:\(username)"
        case .reviewRequest:
            searchQuery = "is:pr is:open review-requested:\(username)"
        }

        let query = buildGraphQLQuery(searchQuery: searchQuery)
        let responseData = try await executeGraphQL(query: query)
        return try parseSearchResponse(data: responseData, category: category)
    }

    func fetchAllPullRequests(username: String) async throws -> [PullRequest] {
        async let authoredPRs = fetchPullRequests(username: username, category: .authored)
        async let reviewPRs = fetchPullRequests(username: username, category: .reviewRequest)

        let (authored, reviews) = try await (authoredPRs, reviewPRs)

        // Deduplicate by PR id (in case same PR appears in both)
        var seen = Set<Int>()
        var result: [PullRequest] = []

        for pr in authored {
            if !seen.contains(pr.id) {
                seen.insert(pr.id)
                result.append(pr)
            }
        }

        for pr in reviews {
            if !seen.contains(pr.id) {
                seen.insert(pr.id)
                result.append(pr)
            }
        }

        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func validateToken() async throws -> Bool {
        let query = """
        query {
            viewer {
                login
            }
        }
        """

        do {
            _ = try await executeGraphQL(query: query)
            return true
        } catch APIError.unauthorized {
            return false
        }
    }

    // MARK: - Private

    private func buildGraphQLQuery(searchQuery: String) -> String {
        """
        query {
            search(query: "\(searchQuery)", type: ISSUE, first: 50) {
                nodes {
                    ... on PullRequest {
                        databaseId
                        number
                        title
                        url
                        state
                        isDraft
                        createdAt
                        updatedAt
                        author {
                            login
                            avatarUrl
                        }
                        repository {
                            owner {
                                login
                            }
                            name
                        }
                        reviewThreads(first: 100) {
                            nodes {
                                id
                                isResolved
                                isOutdated
                                path
                                line
                                comments(first: 10) {
                                    nodes {
                                        id
                                        author {
                                            login
                                        }
                                        body
                                        createdAt
                                    }
                                }
                            }
                        }
                        commits(last: 1) {
                            nodes {
                                commit {
                                    statusCheckRollup {
                                        state
                                        contexts(first: 100) {
                                            nodes {
                                                ... on CheckRun {
                                                    conclusion
                                                }
                                                ... on StatusContext {
                                                    context
                                                    state
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                pageInfo {
                    hasNextPage
                    endCursor
                }
            }
        }
        """
    }

    private func executeGraphQL(query: String) async throws -> Data {
        var request = URLRequest(url: graphQLURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let body = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            // Check for GraphQL errors in response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = json["errors"] as? [[String: Any]],
               let firstError = errors.first,
               let message = firstError["message"] as? String {
                throw APIError.unknown(message)
            }
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            // Check for rate limiting
            if let resetTime = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"),
               let timestamp = TimeInterval(resetTime) {
                let resetDate = Date(timeIntervalSince1970: timestamp)
                throw APIError.rateLimited(resetDate: resetDate)
            }
            throw APIError.unauthorized
        default:
            throw APIError.unknown("HTTP \(httpResponse.statusCode)")
        }
    }

    private func parseSearchResponse(data: Data, category: PRCategory) throws -> [PullRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let response = try decoder.decode(GraphQLResponse.self, from: data)
            return response.data.search.nodes.compactMap { node in
                guard let databaseId = node.databaseId else { return nil }

                let reviewThreads = node.reviewThreads?.nodes.map { thread -> ReviewThread in
                    let comments = thread.comments.nodes.map { comment -> ReviewComment in
                        ReviewComment(
                            id: comment.id,
                            author: comment.author?.login ?? "unknown",
                            body: comment.body,
                            createdAt: comment.createdAt
                        )
                    }
                    return ReviewThread(
                        id: thread.id,
                        isResolved: thread.isResolved,
                        isOutdated: thread.isOutdated,
                        path: thread.path,
                        line: thread.line,
                        comments: comments
                    )
                } ?? []

                // Extract CI status and counts from the last commit
                let statusCheckRollup = node.commits?.nodes.first?.commit.statusCheckRollup

                // Count check statuses
                var successCount = 0
                var failureCount = 0
                var pendingCount = 0

                if let contexts = statusCheckRollup?.contexts?.nodes {
                    for context in contexts {
                        // CheckRun uses conclusion, StatusContext uses state
                        if let conclusion = context.conclusion {
                            switch conclusion.uppercased() {
                            case "SUCCESS":
                                successCount += 1
                            case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE":
                                failureCount += 1
                            case "CANCELLED", "SKIPPED", "NEUTRAL", "STALE":
                                // Don't count cancelled/skipped/neutral in totals
                                break
                            default:
                                pendingCount += 1  // null or unknown = in progress
                            }
                        } else if let state = context.state {
                            // Skip status contexts matching exclude filter (only show CI checks)
                            let excludeFilter = Self.loadCIStatusExcludeFilter()
                            if !excludeFilter.isEmpty,
                               let contextName = context.context,
                               contextName.lowercased().contains(excludeFilter.lowercased()) {
                                continue
                            }
                            switch state.uppercased() {
                            case "SUCCESS":
                                successCount += 1
                            case "FAILURE", "ERROR":
                                failureCount += 1
                            case "PENDING", "EXPECTED":
                                pendingCount += 1
                            default:
                                break
                            }
                        } else {
                            // No conclusion or state means in progress
                            pendingCount += 1
                        }
                    }
                }

                // Derive CI status from our counts (not GitHub's rollup which may include excluded checks)
                let ciStatus: CIStatus?
                if failureCount > 0 {
                    ciStatus = .failure
                } else if pendingCount > 0 {
                    ciStatus = .pending
                } else if successCount > 0 {
                    ciStatus = .success
                } else if statusCheckRollup != nil {
                    // No checks we count, but rollup exists - use expected
                    ciStatus = .expected
                } else {
                    ciStatus = nil
                }

                return PullRequest(
                    id: databaseId,
                    number: node.number,
                    title: node.title,
                    author: node.author?.login ?? "unknown",
                    authorAvatarURL: node.author?.avatarUrl,
                    repositoryOwner: node.repository.owner.login,
                    repositoryName: node.repository.name,
                    url: node.url,
                    state: PRState(rawValue: node.state) ?? .open,
                    isDraft: node.isDraft,
                    createdAt: node.createdAt,
                    updatedAt: node.updatedAt,
                    reviewThreads: reviewThreads,
                    category: category,
                    ciStatus: ciStatus,
                    checkSuccessCount: successCount,
                    checkFailureCount: failureCount,
                    checkPendingCount: pendingCount
                )
            }
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Configuration

    private static let configurationKey = "PRDashboard.Configuration"

    private static func loadCIStatusExcludeFilter() -> String {
        guard let data = UserDefaults.standard.data(forKey: configurationKey),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            return Configuration.default.ciStatusExcludeFilter
        }
        return config.ciStatusExcludeFilter
    }
}

// MARK: - GraphQL Response Models

private struct GraphQLResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let search: SearchResult
    }

    struct SearchResult: Decodable {
        let nodes: [PRNode]
        let pageInfo: PageInfo
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct PRNode: Decodable {
        let databaseId: Int?
        let number: Int
        let title: String
        let url: URL
        let state: String
        let isDraft: Bool
        let createdAt: Date
        let updatedAt: Date
        let author: Author?
        let repository: Repository
        let reviewThreads: ReviewThreadsContainer?
        let commits: CommitsContainer?
    }

    struct Author: Decodable {
        let login: String
        let avatarUrl: URL?
    }

    struct Repository: Decodable {
        let owner: Owner
        let name: String
    }

    struct Owner: Decodable {
        let login: String
    }

    struct ReviewThreadsContainer: Decodable {
        let nodes: [ReviewThreadNode]
    }

    struct ReviewThreadNode: Decodable {
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let path: String?
        let line: Int?
        let comments: CommentsContainer
    }

    struct CommentsContainer: Decodable {
        let nodes: [CommentNode]
    }

    struct CommentNode: Decodable {
        let id: String
        let author: Author?
        let body: String
        let createdAt: Date
    }

    struct CommitsContainer: Decodable {
        let nodes: [CommitNode]
    }

    struct CommitNode: Decodable {
        let commit: CommitInfo
    }

    struct CommitInfo: Decodable {
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable {
        let state: String
        let contexts: ContextsContainer?
    }

    struct ContextsContainer: Decodable {
        let nodes: [ContextNode]
    }

    struct ContextNode: Decodable {
        // CheckRun uses "conclusion", StatusContext uses "state" and "context"
        let conclusion: String?  // SUCCESS, FAILURE, NEUTRAL, CANCELLED, SKIPPED, TIMED_OUT, ACTION_REQUIRED, null (in progress)
        let state: String?       // PENDING, SUCCESS, FAILURE, ERROR, EXPECTED
        let context: String?     // StatusContext name (e.g., "ci/build", "code-review/reviewable")
    }
}
