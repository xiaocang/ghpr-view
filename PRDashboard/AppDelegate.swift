import Cocoa
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var oauthManager: GitHubOAuthManager?
    var prManager: PRManager?
    var notificationManager: NotificationManager?

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Create OAuth manager (loads saved auth automatically)
        oauthManager = GitHubOAuthManager()

        // 2. Create notification manager and request permission
        notificationManager = NotificationManager()

        // 3. Create API client
        let apiClient = GitHubAPIClient(token: oauthManager?.authState.accessToken ?? "")

        // 4. Create PR manager
        prManager = PRManager(
            apiClient: apiClient,
            notificationManager: notificationManager!,
            oauthManager: oauthManager!
        )

        // 5. Create view model
        let viewModel = PRListViewModel(prManager: prManager!, oauthManager: oauthManager!)

        // 6. Create main view
        let mainView = MainView(viewModel: viewModel)

        // 7. Create popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: mainView)

        // 8. Create status bar controller
        statusBarController = StatusBarController(popover: popover, prManager: prManager!)

        // 9. Observe PR list changes to update badge
        prManager?.$prList
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prList in
                self?.statusBarController?.updateBadge(count: prList.totalUnresolvedCount)
            }
            .store(in: &cancellables)

        // 10. Request notification permission if authenticated
        if oauthManager?.authState.isAuthenticated == true {
            notificationManager?.requestPermission()
        }

        // 11. Request notification permission and refresh PRs after sign-in
        oauthManager?.$authState
            .dropFirst()  // Skip initial value
            .filter { $0.isAuthenticated }
            .sink { [weak self] _ in
                self?.notificationManager?.requestPermission()
                Task { @MainActor in
                    self?.prManager?.refresh()
                }
            }
            .store(in: &cancellables)
    }
}
