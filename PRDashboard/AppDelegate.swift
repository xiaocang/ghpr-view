import Cocoa
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?
    var prManager: PRManager?
    var notificationManager: NotificationManager?
    var configurationStore: ConfigurationStore?

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Load configuration
        configurationStore = ConfigurationStore()

        // 2. Create notification manager and request permission
        notificationManager = NotificationManager()
        notificationManager?.requestPermission()

        // 3. Create API client (will be updated when config changes)
        let apiClient = GitHubAPIClient(token: configurationStore?.configuration.githubToken ?? "")

        // 4. Create PR manager
        prManager = PRManager(
            apiClient: apiClient,
            notificationManager: notificationManager!,
            configurationStore: configurationStore!
        )

        // 5. Create view model
        let viewModel = PRListViewModel(prManager: prManager!, configurationStore: configurationStore!)

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
    }
}
