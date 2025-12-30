#!/bin/bash
set -e

APP_NAME="PRDashboard"

# Kill existing instance
pkill -x "$APP_NAME" 2>/dev/null || true

# Build
xcodebuild -project PRDashboard.xcodeproj -scheme PRDashboard -configuration Debug -destination 'platform=macOS,arch=arm64' build -quiet

# Open the built app
open ~/Library/Developer/Xcode/DerivedData/PRDashboard-*/Build/Products/Debug/PRDashboard.app
