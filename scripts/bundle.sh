#!/usr/bin/env bash
# Builds Spring.app from the Swift package and signs it (ad hoc unless SIGN_IDENTITY is set).
#   scripts/bundle.sh [version]            -> build/Spring.app
#   UNIVERSAL=1 scripts/bundle.sh 0.1.0    -> arm64 + x86_64 (needs full Xcode, as on GitHub runners)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCH_FLAGS=()
[ "${UNIVERSAL:-0}" = "1" ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/Spring"

APP=build/Spring.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Spring"
[ -d Resources/Fonts ] && cp -R Resources/Fonts "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Spring</string>
  <key>CFBundleDisplayName</key><string>Spring</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-uk.spring.app}</string>
  <key>CFBundleExecutable</key><string>Spring</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --entitlements Spring.entitlements --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION)"
