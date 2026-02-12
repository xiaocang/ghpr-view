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
    private static let maxCIContextsToFetch = 200
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
        return try await parseCombinedResponse(data: responseData, username: username)
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

    /// Fetches additional CI contexts for a commit when pagination is needed
    func fetchAdditionalCIContexts(owner: String, repo: String, commitOid: String, after: String) async throws -> CIContextsResult {
        let query = """
        query {
            repository(owner: "\(owner)", name: "\(repo)") {
                object(oid: "\(commitOid)") {
                    ... on Commit {
                        statusCheckRollup {
                            contexts(first: 100, after: "\(after)") {
                                nodes {
                                    ... on CheckRun {
                                        name
                                        conclusion
                                    }
                                    ... on StatusContext {
                                        context
                                        state
                                    }
                                }
                                pageInfo {
                                    hasNextPage
                                    endCursor
                                }
                            }
                        }
                    }
                }
            }
        }
        """

        let responseData = try await executeGraphQL(query: query)
        return try parseCIContextsResponse(data: responseData)
    }

    struct CIContextsResult {
        let contexts: [CIContextNode]
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct CIContextNode {
        let name: String?
        let conclusion: String?
        let state: String?
        let context: String?
    }

    private func parseCIContextsResponse(data: Data) throws -> CIContextsResult {
        struct Response: Decodable {
            let data: DataContainer
            struct DataContainer: Decodable {
                let repository: RepositoryContainer?
            }
            struct RepositoryContainer: Decodable {
                let object: ObjectContainer?
            }
            struct ObjectContainer: Decodable {
                let statusCheckRollup: StatusCheckRollup?
            }
            struct StatusCheckRollup: Decodable {
                let contexts: ContextsContainer?
            }
            struct ContextsContainer: Decodable {
                let nodes: [ContextNode]
                let pageInfo: PageInfo?
            }
            struct PageInfo: Decodable {
                let hasNextPage: Bool
                let endCursor: String?
            }
            struct ContextNode: Decodable {
                let name: String?
                let conclusion: String?
                let state: String?
                let context: String?
            }
        }

        let decoder = JSONDecoder.githubDecoder
        let response = try decoder.decode(Response.self, from: data)

        guard let contexts = response.data.repository?.object?.statusCheckRollup?.contexts else {
            return CIContextsResult(contexts: [], hasNextPage: false, endCursor: nil)
        }

        let ciContexts = contexts.nodes.map { node in
            CIContextNode(name: node.name, conclusion: node.conclusion, state: node.state, context: node.context)
        }

        return CIContextsResult(
            contexts: ciContexts,
            hasNextPage: contexts.pageInfo?.hasNextPage ?? false,
            endCursor: contexts.pageInfo?.endCursor
        )
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
                        reviewThreads(last: 20) {
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
                            pageInfo {
                                hasPreviousPage
                                startCursor
                            }
                        }
                        commits(last: 1) {
                            nodes {
                                commit {
                                    oid
                                    committedDate
                                    statusCheckRollup {
                                        state
                                        contexts(first: 20) {
                                            nodes {
                                                ... on CheckRun {
                                                    name
                                                    conclusion
                                                }
                                                ... on StatusContext {
                                                    context
                                                    state
                                                }
                                            }
                                            pageInfo {
                                                hasNextPage
                                                endCursor
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        reviews(author: "\(username)", last: 1) {
                            nodes {
                                state
                                submittedAt
                            }
                        }
                        timelineItems(last: 10, itemTypes: [REVIEW_REQUESTED_EVENT]) {
                            nodes {
                                ... on ReviewRequestedEvent {
                                    createdAt
                                    requestedReviewer {
                                        ... on User {
                                            login
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
                        reviewThreads(last: 20) {
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
                            pageInfo {
                                hasPreviousPage
                                startCursor
                            }
                        }
                        commits(last: 1) {
                            nodes {
                                commit {
                                    oid
                                    committedDate
                                    statusCheckRollup {
                                        state
                                        contexts(first: 20) {
                                            nodes {
                                                ... on CheckRun {
                                                    name
                                                    conclusion
                                                }
                                                ... on StatusContext {
                                                    context
                                                    state
                                                }
                                            }
                                            pageInfo {
                                                hasNextPage
                                                endCursor
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
                    // Track seen CheckRun names to deduplicate re-runs (only count latest)
                    // Reverse the array because GitHub returns oldest first, but we want newest
                    var seenCheckNames = Set<String>()

                    for context in contexts.reversed() {
                        // CheckRun uses conclusion, StatusContext uses state
                        if let conclusion = context.conclusion {
                            // Deduplicate CheckRuns by name (only count latest run)
                            if let name = context.name {
                                if seenCheckNames.contains(name) {
                                    continue  // Skip older run of same check
                                }
                                seenCheckNames.insert(name)
                            }
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
                            // CheckRun with no conclusion means in progress
                            // Deduplicate by name if available
                            if let name = context.name {
                                if seenCheckNames.contains(name) {
                                    continue
                                }
                                seenCheckNames.insert(name)
                            }
                            pendingCount += 1
                        }
                    }
                }

                // Derive CI status from our counts (not GitHub's rollup which may include excluded checks)
                let rollupState = statusCheckRollup?.state
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
                    checkPendingCount: pendingCount,
                    githubCIState: rollupState,
                    myLastReviewState: nil,
                    myLastReviewAt: nil,
                    reviewRequestedAt: nil,
                    myThreadsAllResolved: false
                )
            }
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Info needed to fetch additional review threads for a PR
    private struct ReviewThreadEnrichmentInfo {
        let prId: Int
        let owner: String
        let repo: String
        let number: Int
        let startCursor: String
    }

    /// Info needed to fetch additional CI contexts for a PR
    private struct CIEnrichmentInfo {
        let prId: Int
        let owner: String
        let repo: String
        let commitOid: String
        let endCursor: String
        let rollupState: String
        let initialContextCount: Int  // Number of contexts already fetched in first page
    }

    private func parseCombinedResponse(data: Data, username: String) async throws -> CombinedPRResult {
        let decoder = JSONDecoder.githubDecoder

        do {
            let response = try decoder.decode(CombinedGraphQLResponse.self, from: data)

            logger.info("Raw response node counts - authored: \(response.data.authored.nodes.count), reviewRequested: \(response.data.reviewRequested.nodes.count), reviewedBy: \(response.data.reviewedBy.nodes.count), mergedInvolved: \(response.data.mergedInvolved.nodes.count)")

            // Log first few merged nodes for debugging
            for (idx, node) in response.data.mergedInvolved.nodes.prefix(3).enumerated() {
                logger.debug("mergedInvolved[\(idx)]: #\(node.number) databaseId=\(node.databaseId.map { String($0) } ?? "nil") state=\(node.state) mergedAt=\(node.mergedAt.map { String(describing: $0) } ?? "nil")")
            }

            // Collect enrichment info from all nodes
            var enrichmentInfos: [CIEnrichmentInfo] = []
            var reviewThreadEnrichmentInfos: [ReviewThreadEnrichmentInfo] = []

            // Parse authored PRs
            var authoredPRs = parseNodes(response.data.authored.nodes, category: .authored, enrichmentInfos: &enrichmentInfos, reviewThreadEnrichmentInfos: &reviewThreadEnrichmentInfos)

            // Parse review requested PRs
            var reviewRequestedPRs = parseNodes(response.data.reviewRequested.nodes, category: .reviewRequest, enrichmentInfos: &enrichmentInfos, reviewThreadEnrichmentInfos: &reviewThreadEnrichmentInfos)

            // Parse reviewed-by PRs (PRs user has already reviewed)
            var reviewedByPRs = parseNodes(response.data.reviewedBy.nodes, category: .reviewRequest, enrichmentInfos: &enrichmentInfos, reviewThreadEnrichmentInfos: &reviewThreadEnrichmentInfos)

            // Parse merged PRs where user is involved (author or reviewer)
            // Determine category based on whether user is author
            var mergedInvolvedPRs = parseNodes(
                response.data.mergedInvolved.nodes,
                category: .reviewRequest,
                usernameForAuthoredCheck: username,
                enrichmentInfos: &enrichmentInfos,
                reviewThreadEnrichmentInfos: &reviewThreadEnrichmentInfos
            )
            logger.info("Parsed mergedInvolvedPRs count: \(mergedInvolvedPRs.count)")

            // Enrich PRs where rollup state disagrees with first-page counts (e.g. FAILURE/PENDING not found in first 20 contexts)
            if !enrichmentInfos.isEmpty {
                logger.info("Need to fetch additional CI contexts for \(enrichmentInfos.count) PRs")
                let enrichedCounts = await fetchAllAdditionalCIContexts(enrichmentInfos: enrichmentInfos)

                // Update PR counts with enriched data (add to existing counts from first page)
                func updatePRs(_ prs: inout [PullRequest]) {
                    prs = prs.map { pr in
                        guard let counts = enrichedCounts[pr.id] else { return pr }
                        var updated = pr
                        updated.checkSuccessCount += counts.success
                        updated.checkFailureCount += counts.failure
                        updated.checkPendingCount += counts.pending
                        // Re-derive CI status based on total counts
                        if updated.checkFailureCount > 0 {
                            updated.ciStatus = .failure
                        } else if updated.checkPendingCount > 0 {
                            updated.ciStatus = .pending
                        } else if updated.checkSuccessCount > 0 {
                            updated.ciStatus = .success
                        } else if counts.limitReached && updated.githubCIState?.uppercased() == "FAILURE" {
                            // GitHub says FAILURE but we hit limit without finding failures
                            updated.ciStatus = .unknown
                            logger.info("PR \(updated.id) set to unknown: GitHub says FAILURE but limit reached without finding failures")
                        }
                        return updated
                    }
                }

                updatePRs(&authoredPRs)
                updatePRs(&reviewRequestedPRs)
                updatePRs(&reviewedByPRs)
                updatePRs(&mergedInvolvedPRs)
            }

            // Enrich PRs that have more review threads beyond the first page
            if !reviewThreadEnrichmentInfos.isEmpty {
                logger.info("Need to fetch additional review threads for \(reviewThreadEnrichmentInfos.count) PRs")
                let additionalThreads = await fetchAllAdditionalReviewThreads(enrichmentInfos: reviewThreadEnrichmentInfos)

                func enrichReviewThreads(_ prs: inout [PullRequest]) {
                    prs = prs.map { pr in
                        guard let extra = additionalThreads[pr.id] else { return pr }
                        var updated = pr
                        updated.reviewThreads = extra + pr.reviewThreads
                        return updated
                    }
                }

                enrichReviewThreads(&authoredPRs)
                enrichReviewThreads(&reviewRequestedPRs)
                enrichReviewThreads(&reviewedByPRs)
                enrichReviewThreads(&mergedInvolvedPRs)
            }

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

    private struct CICounts {
        var success: Int
        var failure: Int
        var pending: Int
        var limitReached: Bool
    }

    // MARK: - Review Thread Enrichment

    struct ReviewThreadsResult {
        let threads: [ReviewThread]
        let hasPreviousPage: Bool
        let startCursor: String?
    }

    /// Fetches additional review threads for a PR when pagination is needed
    func fetchAdditionalReviewThreads(owner: String, repo: String, number: Int, before: String) async throws -> ReviewThreadsResult {
        let query = """
        query {
            repository(owner: "\(owner)", name: "\(repo)") {
                pullRequest(number: \(number)) {
                    reviewThreads(last: 20, before: "\(before)") {
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
                        pageInfo {
                            hasPreviousPage
                            startCursor
                        }
                    }
                }
            }
        }
        """

        let responseData = try await executeGraphQL(query: query)
        return try parseReviewThreadsResponse(data: responseData)
    }

    private func parseReviewThreadsResponse(data: Data) throws -> ReviewThreadsResult {
        struct Response: Decodable {
            let data: DataContainer
            struct DataContainer: Decodable {
                let repository: RepositoryContainer?
            }
            struct RepositoryContainer: Decodable {
                let pullRequest: PullRequestContainer?
            }
            struct PullRequestContainer: Decodable {
                let reviewThreads: ReviewThreadsContainer?
            }
            struct ReviewThreadsContainer: Decodable {
                let nodes: [ReviewThreadNode]
                let pageInfo: PageInfo?
            }
            struct PageInfo: Decodable {
                let hasPreviousPage: Bool
                let startCursor: String?
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
            struct Author: Decodable {
                let login: String
            }
        }

        let decoder = JSONDecoder.githubDecoder
        let response = try decoder.decode(Response.self, from: data)

        guard let reviewThreads = response.data.repository?.pullRequest?.reviewThreads else {
            return ReviewThreadsResult(threads: [], hasPreviousPage: false, startCursor: nil)
        }

        let threads = reviewThreads.nodes.map { node in
            let comments = node.comments.nodes.map { comment in
                ReviewComment(
                    id: comment.id,
                    author: comment.author?.login ?? "unknown",
                    body: comment.body,
                    createdAt: comment.createdAt
                )
            }
            return ReviewThread(
                id: node.id,
                isResolved: node.isResolved,
                isOutdated: node.isOutdated,
                path: node.path,
                line: node.line,
                comments: comments
            )
        }

        return ReviewThreadsResult(
            threads: threads,
            hasPreviousPage: reviewThreads.pageInfo?.hasPreviousPage ?? false,
            startCursor: reviewThreads.pageInfo?.startCursor
        )
    }

    /// Fetches all additional review threads for PRs that need enrichment
    private func fetchAllAdditionalReviewThreads(enrichmentInfos: [ReviewThreadEnrichmentInfo]) async -> [Int: [ReviewThread]] {
        var results: [Int: [ReviewThread]] = [:]

        for info in enrichmentInfos {
            do {
                var allThreads: [ReviewThread] = []
                var cursor: String? = info.startCursor

                while let currentCursor = cursor {
                    let result = try await fetchAdditionalReviewThreads(
                        owner: info.owner,
                        repo: info.repo,
                        number: info.number,
                        before: currentCursor
                    )
                    allThreads.append(contentsOf: result.threads)
                    cursor = result.hasPreviousPage ? result.startCursor : nil
                }

                if !allThreads.isEmpty {
                    results[info.prId] = allThreads
                    logger.info("Enriched review threads for PR \(info.prId) (#\(info.number)): fetched \(allThreads.count) additional threads")
                }
            } catch {
                logger.error("Failed to fetch additional review threads for PR \(info.prId) (#\(info.number)): \(error.localizedDescription)")
            }
        }

        return results
    }

    /// Fetches additional CI contexts for all PRs that need enrichment
    private func fetchAllAdditionalCIContexts(enrichmentInfos: [CIEnrichmentInfo]) async -> [Int: CICounts] {
        var results: [Int: CICounts] = [:]

        for info in enrichmentInfos {
            do {
                let counts = try await fetchFullCIContexts(
                    owner: info.owner,
                    repo: info.repo,
                    commitOid: info.commitOid,
                    startCursor: info.endCursor,
                    initialCount: info.initialContextCount
                )
                results[info.prId] = counts
                logger.info("Enriched CI for PR \(info.prId): \(counts.success) success, \(counts.failure) failure, \(counts.pending) pending, limitReached=\(counts.limitReached)")
            } catch {
                logger.error("Failed to fetch additional CI contexts for PR \(info.prId): \(error.localizedDescription)")
            }
        }

        return results
    }

    /// Fetches all remaining CI contexts for a commit, paginating as needed
    /// Returns counts and whether the limit was reached before exhausting all pages
    private func fetchFullCIContexts(owner: String, repo: String, commitOid: String, startCursor: String, initialCount: Int) async throws -> CICounts {
        var counts = CICounts(success: 0, failure: 0, pending: 0, limitReached: false)
        var seenCheckNames = Set<String>()
        var cursor: String? = startCursor
        let excludeFilter = Self.loadCIStatusExcludeFilter()
        var totalFetched = initialCount

        while let currentCursor = cursor {
            let result = try await fetchAdditionalCIContexts(owner: owner, repo: repo, commitOid: commitOid, after: currentCursor)
            totalFetched += result.contexts.count

            for context in result.contexts.reversed() {
                if let conclusion = context.conclusion {
                    if let name = context.name {
                        if seenCheckNames.contains(name) { continue }
                        seenCheckNames.insert(name)
                    }
                    switch conclusion.uppercased() {
                    case "SUCCESS":
                        counts.success += 1
                    case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE":
                        counts.failure += 1
                    case "CANCELLED", "SKIPPED", "NEUTRAL", "STALE":
                        break
                    default:
                        counts.pending += 1
                    }
                } else if let state = context.state {
                    if !excludeFilter.isEmpty,
                       let contextName = context.context,
                       contextName.lowercased().contains(excludeFilter.lowercased()) {
                        continue
                    }
                    switch state.uppercased() {
                    case "SUCCESS":
                        counts.success += 1
                    case "FAILURE", "ERROR":
                        counts.failure += 1
                    case "PENDING", "EXPECTED":
                        counts.pending += 1
                    default:
                        break
                    }
                } else {
                    if let name = context.name {
                        if seenCheckNames.contains(name) { continue }
                        seenCheckNames.insert(name)
                    }
                    counts.pending += 1
                }
            }

            // Check if we've reached the limit
            if totalFetched >= Self.maxCIContextsToFetch {
                if result.hasNextPage {
                    logger.warning("Reached CI context limit (\(Self.maxCIContextsToFetch)) for \(owner)/\(repo)@\(commitOid), more pages available")
                    counts.limitReached = true
                }
                break
            }

            cursor = result.hasNextPage ? result.endCursor : nil
        }

        return counts
    }

    private func parseNodes(
        _ nodes: [CombinedGraphQLResponse.PRNode],
        category: PRCategory,
        usernameForAuthoredCheck: String? = nil,
        enrichmentInfos: inout [CIEnrichmentInfo],
        reviewThreadEnrichmentInfos: inout [ReviewThreadEnrichmentInfo]
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

            // Check if we need to fetch more review threads
            if let pageInfo = node.reviewThreads?.pageInfo,
               pageInfo.hasPreviousPage,
               let startCursor = pageInfo.startCursor {
                reviewThreadEnrichmentInfos.append(ReviewThreadEnrichmentInfo(
                    prId: databaseId,
                    owner: node.repository.owner.login,
                    repo: node.repository.name,
                    number: node.number,
                    startCursor: startCursor
                ))
            }

            // Extract CI status and counts from the last commit
            let lastCommit = node.commits?.nodes.first?.commit
            let statusCheckRollup = lastCommit?.statusCheckRollup
            let lastCommitAt = lastCommit?.committedDate

            // Count check statuses
            var successCount = 0
            var failureCount = 0
            var pendingCount = 0

            if let contexts = statusCheckRollup?.contexts?.nodes {
                // Track seen CheckRun names to deduplicate re-runs (only count latest)
                // Reverse the array because GitHub returns oldest first, but we want newest
                var seenCheckNames = Set<String>()

                for context in contexts.reversed() {
                    // CheckRun uses conclusion, StatusContext uses state
                    if let conclusion = context.conclusion {
                        // Deduplicate CheckRuns by name (only count latest run)
                        if let name = context.name {
                            if seenCheckNames.contains(name) {
                                continue  // Skip older run of same check
                            }
                            seenCheckNames.insert(name)
                        }
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
                        // CheckRun with no conclusion means in progress
                        // Deduplicate by name if available
                        if let name = context.name {
                            if seenCheckNames.contains(name) {
                                continue
                            }
                            seenCheckNames.insert(name)
                        }
                        pendingCount += 1
                    }
                }
            }

            // Check if we need to fetch more CI contexts:
            // - Rollup state disagrees with first-page counts (FAILURE with no failures, or PENDING with no pending)
            // - And there are more pages to fetch
            let rollupState = statusCheckRollup?.state ?? ""
            let upperRollup = rollupState.uppercased()
            let initialContextCount = statusCheckRollup?.contexts?.nodes.count ?? 0
            if ((upperRollup == "FAILURE" && failureCount == 0) ||
                (upperRollup == "PENDING" && pendingCount == 0)),
               let pageInfo = statusCheckRollup?.contexts?.pageInfo,
               pageInfo.hasNextPage,
               let endCursor = pageInfo.endCursor,
               let commitOid = lastCommit?.oid {
                enrichmentInfos.append(CIEnrichmentInfo(
                    prId: databaseId,
                    owner: node.repository.owner.login,
                    repo: node.repository.name,
                    commitOid: commitOid,
                    endCursor: endCursor,
                    rollupState: rollupState,
                    initialContextCount: initialContextCount
                ))
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

            // Extract my review data
            let lastReview = node.reviews?.nodes.first
            let myLastReviewState: ReviewState? = lastReview.flatMap { ReviewState(rawValue: $0.state) }
            let myLastReviewAt: Date? = lastReview?.submittedAt

            // Extract the most recent review request for the current user
            let reviewRequestedAt: Date? = node.timelineItems?.nodes
                .filter { $0.requestedReviewer?.login?.lowercased() == usernameLower }
                .compactMap { $0.createdAt }
                .max()

            // Check if all threads started by user are resolved
            let myThreadsAllResolved: Bool = {
                guard let usernameLower else { return false }
                let myThreads = reviewThreads.filter { thread in
                    thread.comments.first?.author.lowercased() == usernameLower
                }
                // If no threads started by user, don't consider it "resolved" (vacuously true would be misleading)
                // Only return true if user has threads AND all are resolved
                return !myThreads.isEmpty && myThreads.allSatisfy { $0.isResolved }
            }()

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
                checkPendingCount: pendingCount,
                githubCIState: rollupState.isEmpty ? nil : rollupState,
                myLastReviewState: myLastReviewState,
                myLastReviewAt: myLastReviewAt,
                reviewRequestedAt: reviewRequestedAt,
                myThreadsAllResolved: myThreadsAllResolved
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
        let pageInfo: ReviewThreadPageInfo?
    }

    struct ReviewThreadPageInfo: Decodable {
        let hasPreviousPage: Bool
        let startCursor: String?
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
        let oid: String?
        let committedDate: Date?
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable {
        let state: String
        let contexts: ContextsContainer?
    }

    struct ContextsContainer: Decodable {
        let nodes: [ContextNode]
        let pageInfo: PageInfoContext?
    }

    struct PageInfoContext: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct ContextNode: Decodable {
        // CheckRun uses "name" and "conclusion", StatusContext uses "state" and "context"
        let name: String?        // CheckRun name (e.g., "build", "test")
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
        let reviews: ReviewsContainer?
        let timelineItems: TimelineItemsContainer?
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
        let pageInfo: ReviewThreadPageInfo?
    }

    struct ReviewThreadPageInfo: Decodable {
        let hasPreviousPage: Bool
        let startCursor: String?
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
        let oid: String?
        let committedDate: Date?
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable {
        let state: String
        let contexts: ContextsContainer?
    }

    struct ContextsContainer: Decodable {
        let nodes: [ContextNode]
        let pageInfo: PageInfoContext?
    }

    struct PageInfoContext: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct ContextNode: Decodable {
        let name: String?
        let conclusion: String?
        let state: String?
        let context: String?
    }

    struct ReviewsContainer: Decodable {
        let nodes: [ReviewNode]
    }

    struct ReviewNode: Decodable {
        let state: String
        let submittedAt: Date?
    }

    struct TimelineItemsContainer: Decodable {
        let nodes: [TimelineItemNode]
    }

    struct TimelineItemNode: Decodable {
        let createdAt: Date?
        let requestedReviewer: RequestedReviewer?
    }

    struct RequestedReviewer: Decodable {
        let login: String?
    }
}
