import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: PRListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var token: String = ""
    @State private var username: String = ""
    @State private var refreshInterval: Double = 60
    @State private var repositories: String = ""
    @State private var showDrafts: Bool = true
    @State private var notificationsEnabled: Bool = true

    @State private var isValidating: Bool = false
    @State private var validationResult: Bool?
    @State private var saveError: String?

    private let refreshIntervalOptions: [(String, Double)] = [
        ("15 seconds", 15),
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            // Settings form
            Form {
                Section("GitHub Account") {
                    SecureField("Personal Access Token", text: $token)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder)

                        Button(action: validateToken) {
                            if isValidating {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Text("Validate")
                            }
                        }
                        .disabled(token.isEmpty || isValidating)
                    }

                    if let result = validationResult {
                        HStack {
                            Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(result ? .green : .red)
                            Text(result ? "Token is valid" : "Invalid token")
                                .font(.caption)
                                .foregroundColor(result ? .green : .red)
                        }
                    }

                    Text("Create a token at GitHub → Settings → Developer settings → Personal access tokens. Required scopes: repo, read:org")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Refresh") {
                    Picker("Refresh Interval", selection: $refreshInterval) {
                        ForEach(refreshIntervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                }

                Section("Filters") {
                    TextField("Repositories (comma-separated, leave empty for all)", text: $repositories)
                        .textFieldStyle(.roundedBorder)

                    Toggle("Show draft PRs", isOn: $showDrafts)
                }

                Section("Notifications") {
                    Toggle("Enable notifications for new unresolved comments", isOn: $notificationsEnabled)
                }

                if let error = saveError {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(token.isEmpty || username.isEmpty)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .onAppear {
            loadCurrentSettings()
        }
    }

    private func loadCurrentSettings() {
        let config = viewModel.configuration
        token = config.githubToken
        username = config.username
        refreshInterval = config.refreshInterval
        repositories = config.repositories.joined(separator: ", ")
        showDrafts = config.showDrafts
        notificationsEnabled = config.notificationsEnabled
    }

    private func validateToken() {
        isValidating = true
        validationResult = nil

        let client = GitHubAPIClient(token: token)

        Task {
            let result = try? await client.validateToken()
            await MainActor.run {
                isValidating = false
                validationResult = result ?? false
            }
        }
    }

    private func save() {
        let repos = repositories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let config = Configuration(
            githubToken: token,
            username: username,
            refreshInterval: refreshInterval,
            repositories: repos,
            showDrafts: showDrafts,
            notificationsEnabled: notificationsEnabled
        )

        do {
            try viewModel.saveConfiguration(config)
            saveError = nil
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView(viewModel: PRListViewModel(
        prManager: PRManager(
            apiClient: GitHubAPIClient(token: ""),
            notificationManager: NotificationManager(),
            configurationStore: ConfigurationStore()
        ),
        configurationStore: ConfigurationStore()
    ))
}
