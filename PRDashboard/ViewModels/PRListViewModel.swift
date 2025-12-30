import Foundation
import Combine
import AppKit

final class PRListViewModel: ObservableObject {
    @Published var prList: PRList = .empty
    @Published var searchText: String = ""
    @Published var showingSettings: Bool = false
    @Published var configuration: Configuration = .default

    private let prManager: PRManager
    private let configurationStore: ConfigurationStore
    private var cancellables = Set<AnyCancellable>()

    init(prManager: PRManager, configurationStore: ConfigurationStore) {
        self.prManager = prManager
        self.configurationStore = configurationStore

        // Bind prList from manager
        prManager.$prList
            .receive(on: DispatchQueue.main)
            .assign(to: &$prList)

        // Bind configuration
        configurationStore.$configuration
            .receive(on: DispatchQueue.main)
            .assign(to: &$configuration)
    }

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

    var isConfigured: Bool {
        configuration.isValid
    }

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

    func saveConfiguration(_ config: Configuration) throws {
        try configurationStore.save(config)
    }

    // MARK: - Private

    private func groupByRepo(_ prs: [PullRequest]) -> [(String, [PullRequest])] {
        let grouped = Dictionary(grouping: prs) { $0.repoFullName }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.0 < $1.0 }
    }
}
