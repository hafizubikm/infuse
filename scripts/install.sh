#!/usr/bin/env bash
#
# Builds a Release Reel.app and installs it to /Applications (ad-hoc signed),
# then registers it with Launch Services so "Open With" and double-click pick it up.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build-ffmpeg.sh"

xcodebuild -project Reel.xcodeproj -scheme Reel -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build \
  | grep -E "error:|warning: .*Reel/|BUILD (SUCCEEDED|FAILED)" || true

APP="build/DerivedData/Build/Products/Release/Reel.app"
[[ -d "$APP" ]] || { echo "error: build failed, $APP not found" >&2; exit 1; }

if pgrep -x Reel >/dev/null; then osascript -e 'quit app "Reel"' || true; sleep 1; fi
rm -rf /Applications/Reel.app
cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Reel.app
echo "Installed /Applications/Reel.app"
