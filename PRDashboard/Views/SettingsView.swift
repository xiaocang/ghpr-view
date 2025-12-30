import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: PRListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var refreshInterval: Double = 60
    @State private var repositories: String = ""
    @State private var showDrafts: Bool = true
    @State private var notificationsEnabled: Bool = true

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
                    save()
                }
                .keyboardShortcut(.return)
            }
            .padding()

            Divider()

            // Settings form
            Form {
                Section("Account") {
                    if viewModel.authState.isAuthenticated {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.accentColor)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.authState.username ?? "Signed in")
                                    .font(.headline)
                                Text("Connected to GitHub")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button("Sign Out") {
                                viewModel.signOut()
                                dismiss()
                            }
                            .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button("Sign in with GitHub") {
                            viewModel.signIn()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
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

                    Text("Example: owner/repo1, owner/repo2")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Show draft PRs", isOn: $showDrafts)
                }

                Section("Notifications") {
                    Toggle("Enable notifications for new unresolved comments", isOn: $notificationsEnabled)
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
            }
            .padding()
        }
        .frame(width: 450, height: 450)
        .onAppear {
            loadCurrentSettings()
        }
    }

    private func loadCurrentSettings() {
        let config = viewModel.configuration
        refreshInterval = config.refreshInterval
        repositories = config.repositories.joined(separator: ", ")
        showDrafts = config.showDrafts
        notificationsEnabled = config.notificationsEnabled
    }

    private func save() {
        let repos = repositories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let config = Configuration(
            refreshInterval: refreshInterval,
            repositories: repos,
            showDrafts: showDrafts,
            notificationsEnabled: notificationsEnabled
        )

        viewModel.configuration = config
        dismiss()
    }
}
