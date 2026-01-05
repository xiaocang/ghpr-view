import SwiftUI

struct MainView: View {
    @ObservedObject var viewModel: PRListViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.authState.isAuthenticated {
                // Header
                headerView

                Divider()

                if viewModel.prList.isLoading && viewModel.prList.pullRequests.isEmpty {
                    // Loading state
                    loadingView
                } else if let error = viewModel.prList.error {
                    // Error state
                    errorView(error)
                } else if viewModel.filteredPRs.isEmpty {
                    // Empty state
                    emptyView
                } else {
                    // PR list
                    prListView
                }

                Divider()

                // Footer
                footerView
            } else {
                // Auth view
                AuthView(viewModel: viewModel)
            }
        }
        .frame(width: 400, height: 500)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search PRs...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(6)

            Spacer()

            // Refresh button
            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel.prList.isLoading)

            // Settings button
            Button(action: { viewModel.showSettings() }) {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
    }

    // MARK: - PR List

    private var prListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // My PRs section
                if !viewModel.authoredPRs.isEmpty {
                    sectionHeader("My PRs", count: viewModel.authoredPRs.count)

                    ForEach(viewModel.groupedAuthoredPRs, id: \.0) { repo, prs in
                        repoSection(repo: repo, prs: prs)
                    }
                }

                // Review Requests section
                if !viewModel.reviewRequestPRs.isEmpty {
                    sectionHeader("Review Requests", count: viewModel.reviewRequestPRs.count)

                    ForEach(viewModel.groupedReviewPRs, id: \.0) { repo, prs in
                        repoSection(repo: repo, prs: prs)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text("(\(count))")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func repoSection(repo: String, prs: [PullRequest]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(prs) { pr in
                PRRowView(
                    pr: pr,
                    onOpen: { viewModel.openPR(pr) },
                    onCopyURL: { viewModel.copyURL(pr) }
                )
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading pull requests...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)

            Text("Failed to load PRs")
                .font(.headline)

            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Retry") {
                viewModel.refresh()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No pull requests")
                .font(.headline)

            Text("You have no open PRs or review requests")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if viewModel.prList.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                Text("Updating...")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                Text("Updated \(viewModel.lastUpdatedFormatted)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if viewModel.totalUnresolvedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 10))
                    Text("\(viewModel.totalUnresolvedCount) unresolved")
                        .font(.system(size: 10))
                }
                .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Auth View

struct AuthView: View {
    @ObservedObject var viewModel: PRListViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App Icon
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            // Title
            VStack(spacing: 8) {
                Text("PR Dashboard")
                    .font(.system(size: 20, weight: .semibold))

                Text("Track your GitHub pull requests\nand unresolved comments")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if let deviceCode = viewModel.deviceCode {
                // Device code view
                deviceCodeView(deviceCode)
            } else {
                // Sign in button
                Button(action: { viewModel.signIn() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle")
                        Text("Sign in with GitHub")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)
                .disabled(viewModel.isAuthenticating)

                // Info text
                Text("Uses GitHub Device Flow for secure authentication")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Error display
            if let error = viewModel.authError {
                Text(error.localizedDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func deviceCodeView(_ deviceCode: DeviceCodeInfo) -> some View {
        VStack(spacing: 16) {
            // Instructions
            Text("Enter this code on GitHub:")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            // User code display
            HStack(spacing: 4) {
                Text(deviceCode.userCode)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)

                Button(action: { viewModel.copyUserCode() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            // Open link button
            Button(action: { viewModel.openVerificationURL() }) {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("Open github.com/login/device")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)

            // Waiting indicator
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Waiting for authorization...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Cancel button
            Button("Cancel") {
                viewModel.cancelSignIn()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.system(size: 12))
        }
    }
}
