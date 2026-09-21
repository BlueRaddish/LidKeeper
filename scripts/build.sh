#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
APP="dist/LidKeeper.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/LidKeeper "$APP/Contents/MacOS/LidKeeper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
