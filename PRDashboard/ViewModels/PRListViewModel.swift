import Foundation
import Combine
import AppKit

@MainActor
final class PRListViewModel: ObservableObject {
    @Published var prList: PRList = .empty
    @Published var searchText: String = ""
    @Published var showingSettings: Bool = false
    @Published private(set) var authState: AuthState = .empty

    private let prManager: PRManager
    private let oauthManager: GitHubOAuthManager
    private var cancellables = Set<AnyCancellable>()

    init(prManager: PRManager, oauthManager: GitHubOAuthManager) {
        self.prManager = prManager
        self.oauthManager = oauthManager

        setupBindings()
    }

    private func setupBindings() {
        // Bind prList from manager
        prManager.$prList
            .receive(on: DispatchQueue.main)
            .assign(to: &$prList)

        // Bind auth state
        oauthManager.$authState
            .receive(on: DispatchQueue.main)
            .assign(to: &$authState)
    }

    // MARK: - Computed Properties

    var filteredPRs: [PullRequest] {
        let prs = prList.pullRequests

        guard !searchText.isEmpty else { return prs }

        let query = searchText.lowercased()
        return prs.filter { pr in
            pr.title.lowercased().contains(query) ||
            pr.repoFullName.lowercased().contains(query) ||
            pr.author.lowercased().contains(query) ||
            String(pr.number).contains(query)
        }
    }

    var authoredPRs: [PullRequest] {
        filteredPRs.filter { $0.category == .authored }
    }

    var reviewRequestPRs: [PullRequest] {
        filteredPRs.filter { $0.category == .reviewRequest }
    }

    var groupedAuthoredPRs: [(String, [PullRequest])] {
        groupByRepo(authoredPRs)
    }

    var groupedReviewPRs: [(String, [PullRequest])] {
        groupByRepo(reviewRequestPRs)
    }

    var totalUnresolvedCount: Int {
        prList.totalUnresolvedCount
    }

    var lastUpdatedFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: prList.lastUpdated, relativeTo: Date())
    }

    var isLoading: Bool {
        prList.isLoading
    }

    var error: Error? {
        prList.error
    }

    var configuration: Configuration {
        get { prManager.configuration }
        set { prManager.updateConfiguration(newValue) }
    }

    // MARK: - Actions

    func refresh() {
        prManager.refresh()
    }

    func openPR(_ pr: PullRequest) {
        NSWorkspace.shared.open(pr.url)
    }

    func copyURL(_ pr: PullRequest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
    }

    func signIn() {
        oauthManager.signIn()
    }

    func signOut() {
        oauthManager.signOut()
    }

    // MARK: - Private

    private func groupByRepo(_ prs: [PullRequest]) -> [(String, [PullRequest])] {
        let grouped = Dictionary(grouping: prs) { $0.repoFullName }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.0 < $1.0 }
    }
}
