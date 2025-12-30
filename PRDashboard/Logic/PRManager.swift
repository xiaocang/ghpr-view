import Foundation
import Combine

protocol PRManagerType: AnyObject {
    func enablePolling(_ enabled: Bool)
    func refresh()
}

final class PRManager: PRManagerType, ObservableObject {
    @Published private(set) var prList: PRList = .empty
    @Published private(set) var refreshState: RefreshState = .idle

    enum RefreshState {
        case idle
        case loading
        case error(Error)
    }

    private var apiClient: GitHubAPIClient
    private let notificationManager: NotificationManager
    private let configurationStore: ConfigurationStore

    private var timer: Timer?
    private var previousPRs: [Int: PullRequest] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(
        apiClient: GitHubAPIClient,
        notificationManager: NotificationManager,
        configurationStore: ConfigurationStore
    ) {
        self.apiClient = apiClient
        self.notificationManager = notificationManager
        self.configurationStore = configurationStore

        // Update API client when token changes
        configurationStore.$configuration
            .sink { [weak self] config in
                self?.apiClient.updateToken(config.githubToken)
            }
            .store(in: &cancellables)
    }

    func enablePolling(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil

        if enabled {
            // Immediate refresh when polling starts
            refresh()

            // Schedule periodic refresh
            let interval = configurationStore.configuration.refreshInterval
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func refresh() {
        let config = configurationStore.configuration

        guard config.isValid else {
            prList = PRList(
                lastUpdated: Date(),
                pullRequests: [],
                isLoading: false,
                error: ConfigurationError.invalidRefreshInterval
            )
            return
        }

        refreshState = .loading
        prList = PRList(
            lastUpdated: prList.lastUpdated,
            pullRequests: prList.pullRequests,
            isLoading: true,
            error: nil
        )

        Task { @MainActor in
            do {
                var prs = try await apiClient.fetchAllPullRequests(username: config.username)

                // Filter by configured repositories if any
                if !config.repositories.isEmpty {
                    prs = prs.filter { config.repositories.contains($0.repoFullName) }
                }

                // Filter drafts if disabled
                if !config.showDrafts {
                    prs = prs.filter { !$0.isDraft }
                }

                // Check for changes and notify
                if config.notificationsEnabled {
                    checkForChangesAndNotify(newPRs: prs)
                }

                // Update previous state
                previousPRs = Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0) })

                prList = PRList(
                    lastUpdated: Date(),
                    pullRequests: prs,
                    isLoading: false,
                    error: nil
                )
                refreshState = .idle

            } catch {
                prList = PRList(
                    lastUpdated: prList.lastUpdated,
                    pullRequests: prList.pullRequests,
                    isLoading: false,
                    error: error
                )
                refreshState = .error(error)
            }
        }
    }

    private func checkForChangesAndNotify(newPRs: [PullRequest]) {
        for pr in newPRs {
            guard let previousPR = previousPRs[pr.id] else {
                // This is a new PR we haven't seen before - skip notification
                // (per user preference: only notify on new unresolved comments)
                continue
            }

            let previousUnresolved = previousPR.unresolvedCount
            let currentUnresolved = pr.unresolvedCount

            if currentUnresolved > previousUnresolved {
                let newCount = currentUnresolved - previousUnresolved
                notificationManager.notify(pr: pr, newUnresolvedCount: newCount)
            }
        }
    }
}
