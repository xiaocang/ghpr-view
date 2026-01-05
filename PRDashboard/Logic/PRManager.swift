import Foundation
import Combine

@MainActor
protocol PRManagerType: AnyObject {
    func enablePolling(_ enabled: Bool)
    func refresh()
}

@MainActor
final class PRManager: PRManagerType, ObservableObject {
    @Published private(set) var prList: PRList = .empty
    @Published private(set) var refreshState: RefreshState = .idle
    @Published var configuration: Configuration

    enum RefreshState {
        case idle
        case loading
        case error(Error)
    }

    private var apiClient: GitHubAPIClient
    private let notificationManager: NotificationManager
    private let oauthManager: GitHubOAuthManager

    private var timer: Timer?
    private var previousPRs: [Int: PullRequest] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(
        apiClient: GitHubAPIClient,
        notificationManager: NotificationManager,
        oauthManager: GitHubOAuthManager
    ) {
        self.apiClient = apiClient
        self.notificationManager = notificationManager
        self.oauthManager = oauthManager
        self.configuration = Self.loadConfiguration()

        setupBindings()
    }

    private func setupBindings() {
        // Update API client when auth state changes
        oauthManager.$authState
            .dropFirst()  // Skip initial value
            .sink { [weak self] authState in
                guard let self else { return }
                self.handleAuthStateChange(authState)
            }
            .store(in: &cancellables)
    }

    private func handleAuthStateChange(_ authState: AuthState) {
        print("[PRManager] handleAuthStateChange called, isAuthenticated=\(authState.isAuthenticated), username=\(authState.username ?? "nil")")
        apiClient.updateToken(authState.accessToken ?? "")

        if authState.isAuthenticated {
            print("[PRManager] Calling refresh()...")
            refresh()
        } else {
            prList = .empty
            previousPRs = [:]
        }
    }

    func enablePolling(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil

        if enabled && oauthManager.authState.isAuthenticated {
            // Immediate refresh when polling starts (if enabled)
            if configuration.refreshOnOpen {
                refresh()
            }

            // Schedule periodic refresh
            let interval = max(configuration.refreshInterval, 15)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        guard oauthManager.authState.isAuthenticated,
              let username = oauthManager.authState.username else {
            return
        }

        guard configuration.isValid else {
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
                var prs = try await apiClient.fetchAllPullRequests(username: username)

                // Filter by configured repositories if any (case-insensitive, supports "org/" prefix match)
                if !configuration.repositories.isEmpty {
                    prs = prs.filter { pr in
                        let repoName = pr.repoFullName.lowercased()
                        return configuration.repositories.contains { filter in
                            let filterLower = filter.lowercased()
                            if filterLower.hasSuffix("/") {
                                // Org/author prefix match (e.g., "xiaocang/" matches all repos under xiaocang)
                                return repoName.hasPrefix(filterLower)
                            } else {
                                // Full "owner/repo" match
                                return repoName == filterLower
                            }
                        }
                    }
                }

                // Filter drafts if disabled
                if !configuration.showDrafts {
                    prs = prs.filter { !$0.isDraft }
                }

                // Check for changes and notify
                if configuration.notificationsEnabled {
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

    func updateConfiguration(_ config: Configuration) {
        configuration = config
        Self.saveConfiguration(config)

        // Restart polling with new interval if currently polling
        if timer != nil {
            enablePolling(true)
        }
    }

    private func checkForChangesAndNotify(newPRs: [PullRequest]) {
        for pr in newPRs {
            guard let previousPR = previousPRs[pr.id] else {
                // This is a new PR we haven't seen before - skip notification
                continue
            }

            // Check for unresolved comment changes
            let previousUnresolved = previousPR.unresolvedCount
            let currentUnresolved = pr.unresolvedCount

            if currentUnresolved > previousUnresolved {
                let newCount = currentUnresolved - previousUnresolved
                notificationManager.notify(pr: pr, newUnresolvedCount: newCount)
            }

            // Check for CI status changes
            let previousCI = previousPR.ciStatus
            let currentCI = pr.ciStatus

            if previousCI != currentCI {
                if let newStatus = currentCI,
                   (newStatus == .success || newStatus == .failure) {
                    notificationManager.notifyCIStatusChange(pr: pr, newStatus: newStatus)
                }
            }
        }
    }

    // MARK: - Configuration Persistence

    private static let configurationKey = "PRDashboard.Configuration"

    private static func loadConfiguration() -> Configuration {
        guard let data = UserDefaults.standard.data(forKey: configurationKey),
              let config = try? JSONDecoder().decode(Configuration.self, from: data) else {
            return .default
        }
        return config
    }

    private static func saveConfiguration(_ config: Configuration) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configurationKey)
        }
    }
}
