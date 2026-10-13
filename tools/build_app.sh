#!/usr/bin/env bash
# Regenerates the Xcode project from project.yml and builds Mirada.app.
# Usage: tools/build_app.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-Debug}
xcodegen generate --quiet
xcodebuild -project Mirada.xcodeproj -scheme MiradaApp -configuration "$CONFIG" \
  -derivedDataPath build/dd -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" | sed 's/\x1b\[[0-9;]*m//g' | sort -u
test -d "build/dd/Build/Products/$CONFIG/Mirada.app" && echo "build/dd/Build/Products/$CONFIG/Mirada.app"
