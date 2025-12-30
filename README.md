# PR Dashboard

A lightweight macOS menu bar app for tracking your GitHub pull requests and review requests.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)

## Features

- **Menu Bar App** - Lives in your menu bar, no dock icon clutter
- **PR Overview** - View your authored PRs and review requests in one place
- **Unresolved Comments** - Badge shows total unresolved comment count
- **OAuth Authentication** - Secure GitHub login (no manual token entry)
- **Auto-Refresh** - Configurable refresh interval (15s - 5min)
- **Notifications** - Desktop alerts for new unresolved comments
- **Search** - Filter PRs by title, repo, or author
- **Quick Actions** - Click to open PR in browser, copy URL

## Screenshots

*Coming soon*

## Requirements

- macOS 13.0 or later
- GitHub account
- GitHub OAuth App (see setup below)

## Setup

### 1. Create a GitHub OAuth App

1. Go to [GitHub Developer Settings](https://github.com/settings/developers)
2. Click **New OAuth App**
3. Fill in the details:
   - **Application name**: PR Dashboard (or your preferred name)
   - **Homepage URL**: `https://github.com/yourusername/ghpr-view`
   - **Authorization callback URL**: `ghpr://oauth/callback`
4. Click **Register application**
5. Copy the **Client ID**

### 2. Configure the App

1. Open `PRDashboard/Logic/GitHubOAuthManager.swift`
2. Replace `YOUR_CLIENT_ID` with your GitHub OAuth App Client ID:
   ```swift
   private let clientID = "your_actual_client_id_here"
   ```

### 3. Build and Run

```bash
# Clone the repository
git clone https://github.com/yourusername/ghpr-view.git
cd ghpr-view

# Build
make build

# Run
make run
```

Or open `PRDashboard.xcodeproj` in Xcode and run from there.

## Usage

- **Left-click** menu bar icon - Open PR dashboard
- **Right-click** menu bar icon - Show context menu (Quit)
- **Cmd+R** - Refresh PR list
- **Settings** (gear icon) - Configure refresh interval, filters, notifications

### Settings

- **Refresh Interval** - How often to fetch updates (15s to 5min)
- **Repositories** - Filter to specific repos (comma-separated `owner/repo`)
- **Show Drafts** - Include/exclude draft PRs
- **Notifications** - Enable/disable desktop notifications

## Project Structure

```
PRDashboard/
├── PRDashboardApp.swift      # App entry point
├── AppDelegate.swift         # App lifecycle
├── Logic/
│   ├── GitHubOAuthManager.swift   # OAuth2 with PKCE
│   ├── GitHubAPIClient.swift      # GitHub GraphQL API
│   ├── PRManager.swift            # PR state management
│   ├── NotificationManager.swift  # Desktop notifications
│   └── StatusBarController.swift  # Menu bar icon
├── Models/
│   ├── PullRequest.swift     # PR model
│   ├── ReviewThread.swift    # Review thread model
│   ├── Configuration.swift   # App settings
│   └── PRList.swift          # PR list state
├── ViewModels/
│   └── PRListViewModel.swift # View state
├── Views/
│   ├── MainView.swift        # Main popover view
│   ├── PRRowView.swift       # PR list row
│   ├── SettingsView.swift    # Settings sheet
│   └── Components/
│       └── Badge.swift       # Count badge
├── Storage/
│   └── Keychain.swift        # Secure token storage
└── Helpers/
    └── DateFormatters.swift  # Date utilities
```

## Development

### Prerequisites

- Xcode 15.0+
- macOS 13.0+

### Building

```bash
# Debug build
make build

# Run the app
make run

# Clean build artifacts
make clean
```

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.
