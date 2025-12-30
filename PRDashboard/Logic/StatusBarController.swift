import Cocoa
import SwiftUI

final class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private weak var prManager: PRManagerType?

    private var eventMonitor: Any?

    init(popover: NSPopover, prManager: PRManagerType) {
        self.statusBar = NSStatusBar.system
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = popover
        self.prManager = prManager

        super.init()

        setupStatusBarButton()
        popover.delegate = self
        setupEventMonitor()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupStatusBarButton() {
        guard let button = statusItem.button else { return }

        // Use SF Symbol for menu bar icon (GitHub-like icon)
        if let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Pull Requests") {
            image.isTemplate = true
            button.image = image
        } else {
            // Fallback to text if SF Symbol not available
            button.title = "PR"
        }

        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    private func setupEventMonitor() {
        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let self = self, self.popover.isShown {
                self.hidePopover(self)
            }
        }
    }

    func updateBadge(count: Int) {
        guard let button = statusItem.button else { return }

        if count > 0 {
            // Create attributed string with badge
            let attachment = NSTextAttachment()
            if let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) {
                image.isTemplate = true
                attachment.image = image
            }

            let attributedString = NSMutableAttributedString()

            if let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) {
                image.isTemplate = true
                button.image = image
            }

            // Add badge count as title
            button.title = " \(count > 99 ? "99+" : "\(count)")"
        } else {
            button.title = ""
            if let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) {
                image.isTemplate = true
                button.image = image
            }
        }
    }

    @objc func togglePopover(_ sender: AnyObject) {
        if popover.isShown {
            hidePopover(sender)
        } else {
            showPopover(sender)
        }
    }

    func showPopover(_ sender: AnyObject) {
        guard let button = statusItem.button else { return }

        button.highlight(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func hidePopover(_ sender: AnyObject) {
        popover.performClose(sender)
        statusItem.button?.highlight(false)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        prManager?.enablePolling(true)
    }

    func popoverWillClose(_ notification: Notification) {
        prManager?.enablePolling(false)
        statusItem.button?.highlight(false)
    }
}
