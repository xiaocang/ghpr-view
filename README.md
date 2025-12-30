# PR Dashboard

A lightweight macOS menu bar app for tracking your GitHub pull requests and review requests.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)

## Features

- **Menu Bar App** - Lives in your menu bar, no dock icon clutter
- **PR Overview** - View your authored PRs and review requests in one place
- **Unresolved Comments** - Badge shows total unresolved comment count
- **Secure Authentication** - GitHub Device Flow (no secrets, no tokens to manage)
- **Auto-Refresh** - Configurable refresh interval (15s - 5min)
- **Notifications** - Desktop alerts for new unresolved comments
- **Search** - Filter PRs by title, repo, or author
- **Quick Actions** - Click to open PR in browser, copy URL

## Installation

### Homebrew (Recommended)

```bash
brew install xiaocang/tap/prdashboard
```

### Manual Download

1. Download the latest release from [Releases](https://github.com/xiaocang/ghpr-view/releases)
2. Extract the ZIP file
3. Move `PRDashboard.app` to your Applications folder
4. Open the app (you may need to right-click → Open the first time)

## Usage

1. Click the menu bar icon to open the dashboard
2. Click "Sign in with GitHub"
3. Enter the displayed code at github.com/login/device
4. Once authorized, your PRs will load automatically

### Controls

- **Left-click** menu bar icon - Open PR dashboard
- **Right-click** menu bar icon - Show context menu (Quit)
- **Cmd+R** - Refresh PR list
- **Settings** (gear icon) - Configure refresh interval, filters, notifications

### Settings

- **Refresh Interval** - How often to fetch updates (15s to 5min)
- **Repositories** - Filter to specific repos (comma-separated `owner/repo`)
- **Show Drafts** - Include/exclude draft PRs
- **Notifications** - Enable/disable desktop notifications

## Requirements

- macOS 13.0 or later
- GitHub account

## Building from Source

```bash
git clone https://github.com/xiaocang/ghpr-view.git
cd ghpr-view
./run.sh
```

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.
