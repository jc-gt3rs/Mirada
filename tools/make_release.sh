#!/usr/bin/env bash
# Builds the release artifacts into build/release-<version>/:
#   Mirada-<version>.dmg                   the app, drag-to-Applications
#   mirada-cli-<version>-macos-arm64.zip   the command-line tool
# Usage: tools/make_release.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: tools/make_release.sh <version>}
OUT=build/release-$VERSION
DD=build/dd-release

xcodegen generate --quiet
# Ad-hoc signed: the published app carries no personal certificate or team ID.
# Gatekeeper treats it like any unnotarized app (Open Anyway, once).
xcodebuild -project Mirada.xcodeproj -scheme MiradaApp -configuration Release -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
swift build -c release 2>&1 | grep -E "error:" && exit 1

APP="$DD/Build/Products/Release/Mirada.app"
test "$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")" = "$VERSION"
test "$(.build/release/mirada --version)" = "$VERSION"
codesign --verify --deep --strict "$APP"

rm -rf "${OUT:?}"
mkdir -p "$OUT/dmg" "$OUT/cli/mirada-$VERSION"

cp -R "$APP" "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
cp LICENSE "$OUT/dmg/LICENSE.txt"
cat > "$OUT/dmg/Read me first.txt" <<EOF
Mirada $VERSION
Look at the camera: on-device gaze correction for macOS 14+ on Apple silicon.

1. Drag Mirada to Applications.
2. This build is not notarized. The first time you open it, macOS blocks it:
   go to System Settings > Privacy & Security and click "Open Anyway"
   (on macOS 14 you can also right-click Mirada > Open).
3. Allow camera access.

Use it in Zoom, Meet, Teams, FaceTime or Photo Booth:
install OBS Studio, click "Start Virtual Camera" once and approve its camera
extension, quit OBS, then choose "OBS Virtual Camera" in your call app while
Mirada is running.

https://github.com/jc-gt3rs/Mirada  ·  MIT License
EOF
hdiutil create -quiet -volname "Mirada $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$OUT/Mirada-$VERSION.dmg"

cp .build/release/mirada "$OUT/cli/mirada-$VERSION/"
cp -R .build/release/Mirada_MiradaKit.bundle "$OUT/cli/mirada-$VERSION/"
cp LICENSE THIRD_PARTY_NOTICES.md "$OUT/cli/mirada-$VERSION/"
(cd "$OUT/cli" && ditto -c -k --keepParent "mirada-$VERSION" "../mirada-cli-$VERSION-macos-arm64.zip")

(cd "$OUT" && shasum -a 256 "Mirada-$VERSION.dmg" "mirada-cli-$VERSION-macos-arm64.zip" > SHA256SUMS.txt)
cat "$OUT/SHA256SUMS.txt"
