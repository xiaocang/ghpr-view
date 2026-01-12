import Foundation
import os

private let logger = Logger(subsystem: "com.prdashboard", category: "GitHubAPIClient")

struct RateLimitInfo: Equatable {
    let limit: Int
    let remaining: Int
    let resetDate: Date

    var isLow: Bool {
        remaining < 100
    }

    static var empty: RateLimitInfo {
        RateLimitInfo(limit: 5000, remaining: 5000, resetDate: Date())
    }
}

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

final class GitHubAPIClient: ObservableObject {
    private let graphQLURL = URL(string: "https://api.github.com/graphql")!
    private var token: String
    private let session: URLSession
    private var lastETag: String?

    @Published private(set) var rateLimitInfo: RateLimitInfo = .empty

    init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func updateToken(_ newToken: String) {
        self.token = newToken
    }

    func fetchPullRequests(username: String, searchQuery: String, category: PRCategory) async throws -> [PullRequest] {
        let query = buildGraphQLQuery(searchQuery: searchQuery)
        let responseData = try await executeGraphQL(query: query)
        return try parseSearchResponse(data: responseData, category: category)
    }

    struct CombinedPRResult {
        let openPRs: [PullRequest]
        let mergedPRs: [PullRequest]
    }

    func fetchAllPullRequests(username: String) async throws -> CombinedPRResult {
        // Combined query using GraphQL aliases - single API call instead of 4
        let query = buildCombinedQuery(username: username)
        let responseData = try await executeGraphQL(query: query)
        return try parseCombinedResponse(data: responseData, username: username)
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

    private func buildCombinedQuery(username: String) -> String {
        let prFragment = """
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
                        mergedAt
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
                        reviewThreads(first: 20) {
                            nodes {
                                id
                                isResolved
                                isOutdated
                                path
                                line
                                comments(first: 5) {
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
                                    committedDate
                                    statusCheckRollup {
                                        state
                                        contexts(first: 20) {
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
        """

        let mergedSince = Self.dateStringForSearch(daysBack: 2)

        return """
        query {
            authored: search(query: "is:pr is:open author:\(username)", type: ISSUE, first: 50) {
                \(prFragment)
            }
            reviewRequested: search(query: "is:pr is:open -author:\(username) review-requested:\(username)", type: ISSUE, first: 50) {
                \(prFragment)
            }
            reviewedBy: search(query: "is:pr is:open -author:\(username) reviewed-by:\(username)", type: ISSUE, first: 50) {
                \(prFragment)
            }
            mergedInvolved: search(query: "is:pr is:merged involves:\(username) merged:>=\(mergedSince)", type: ISSUE, first: 50) {
                \(prFragment)
            }
        }
        """
    }

    private static func dateStringForSearch(daysBack: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let sinceDate = calendar.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: sinceDate)
    }

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
                        mergedAt
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
                        reviewThreads(first: 20) {
                            nodes {
                                id
                                isResolved
                                isOutdated
                                path
                                line
                                comments(first: 5) {
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
                                    committedDate
                                    statusCheckRollup {
                                        state
                                        contexts(first: 20) {
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

        // Parse rate limit headers
        if let limitStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Limit"),
           let remainingStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let resetStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let limit = Int(limitStr),
           let remaining = Int(remainingStr),
           let resetTimestamp = TimeInterval(resetStr) {
            Task { @MainActor in
                self.rateLimitInfo = RateLimitInfo(
                    limit: limit,
                    remaining: remaining,
                    resetDate: Date(timeIntervalSince1970: resetTimestamp)
                )
            }
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
        let decoder = JSONDecoder.githubDecoder

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
                let lastCommit = node.commits?.nodes.first?.commit
                let statusCheckRollup = lastCommit?.statusCheckRollup
                let lastCommitAt = lastCommit?.committedDate

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
                    mergedAt: node.mergedAt,
                    lastCommitAt: lastCommitAt,
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

    private func parseCombinedResponse(data: Data, username: String) throws -> CombinedPRResult {
        let decoder = JSONDecoder.githubDecoder

        do {
            let response = try decoder.decode(CombinedGraphQLResponse.self, from: data)

            logger.info("Raw response node counts - authored: \(response.data.authored.nodes.count), reviewRequested: \(response.data.reviewRequested.nodes.count), reviewedBy: \(response.data.reviewedBy.nodes.count), mergedInvolved: \(response.data.mergedInvolved.nodes.count)")

            // Log first few merged nodes for debugging
            for (idx, node) in response.data.mergedInvolved.nodes.prefix(3).enumerated() {
                logger.debug("mergedInvolved[\(idx)]: #\(node.number) databaseId=\(node.databaseId.map { String($0) } ?? "nil") state=\(node.state) mergedAt=\(node.mergedAt.map { String(describing: $0) } ?? "nil")")
            }

            // Parse authored PRs
            let authoredPRs = parseNodes(response.data.authored.nodes, category: .authored)

            // Parse review requested PRs
            let reviewRequestedPRs = parseNodes(response.data.reviewRequested.nodes, category: .reviewRequest)

            // Parse reviewed-by PRs (PRs user has already reviewed)
            let reviewedByPRs = parseNodes(response.data.reviewedBy.nodes, category: .reviewRequest)

            // Parse merged PRs where user is involved (author or reviewer)
            // Determine category based on whether user is author
            let mergedInvolvedPRs = parseNodes(
                response.data.mergedInvolved.nodes,
                category: .reviewRequest,
                usernameForAuthoredCheck: username
            )
            logger.info("Parsed mergedInvolvedPRs count: \(mergedInvolvedPRs.count)")

            // Combine review requested and reviewed-by, deduplicating by ID
            var reviewPRsById: [Int: PullRequest] = [:]
            for pr in reviewRequestedPRs {
                reviewPRsById[pr.id] = pr
            }
            for pr in reviewedByPRs {
                if reviewPRsById[pr.id] == nil {
                    reviewPRsById[pr.id] = pr
                }
            }

            // Combine open PRs and sort by updatedAt (most recent first)
            let openPRs = authoredPRs + Array(reviewPRsById.values)

            // Deduplicate merged results, keep only last 24h by mergedAt, and sort by mergedAt/updatedAt
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            var mergedById: [Int: PullRequest] = [:]
            for pr in mergedInvolvedPRs {
                guard let mergedAt = pr.mergedAt, mergedAt >= cutoff else { continue }
                mergedById[pr.id] = pr
            }
            let mergedPRs = Array(mergedById.values).sorted { ($0.mergedAt ?? $0.updatedAt) > ($1.mergedAt ?? $1.updatedAt) }

            return CombinedPRResult(
                openPRs: openPRs.sorted { $0.updatedAt > $1.updatedAt },
                mergedPRs: mergedPRs
            )
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func parseNodes(
        _ nodes: [CombinedGraphQLResponse.PRNode],
        category: PRCategory,
        usernameForAuthoredCheck: String? = nil
    ) -> [PullRequest] {
        let usernameLower = usernameForAuthoredCheck?.lowercased()
        return nodes.compactMap { node in
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
            let lastCommit = node.commits?.nodes.first?.commit
            let statusCheckRollup = lastCommit?.statusCheckRollup
            let lastCommitAt = lastCommit?.committedDate

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

            // Determine category - if username provided, check if user is author
            let resolvedCategory: PRCategory
            if let usernameLower {
                if node.author?.login.lowercased() == usernameLower {
                    resolvedCategory = .authored
                } else {
                    resolvedCategory = category
                }
            } else {
                resolvedCategory = category
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
                mergedAt: node.mergedAt,
                lastCommitAt: lastCommitAt,
                reviewThreads: reviewThreads,
                category: resolvedCategory,
                ciStatus: ciStatus,
                checkSuccessCount: successCount,
                checkFailureCount: failureCount,
                checkPendingCount: pendingCount
            )
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
        let mergedAt: Date?
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
        let committedDate: Date?
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

// MARK: - Combined GraphQL Response Models (for single-query fetch)

private struct CombinedGraphQLResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let authored: SearchResult
        let reviewRequested: SearchResult
        let reviewedBy: SearchResult
        let mergedInvolved: SearchResult
    }

    struct SearchResult: Decodable {
        let nodes: [PRNode]
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
        let mergedAt: Date?
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
        let committedDate: Date?
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
        let conclusion: String?
        let state: String?
        let context: String?
    }
}
