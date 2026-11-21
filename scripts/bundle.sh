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
BUNDLE_ID="${BUNDLE_ID:-uk.spring.app}"

# Sparkle: the framework sits next to the binary (rpath @executable_path/../Frameworks).
# Updates switch on only when Resources/sparkle-public-key.txt exists (see README).
mkdir -p "$APP/Contents/Frameworks"
FW="$(find .build/artifacts/sparkle -path '*macos*/Sparkle.framework' -maxdepth 4 -print -quit)"
[ -n "$FW" ] || { echo "Sparkle.framework not found; run swift package resolve" >&2; exit 1; }
ditto "$FW" "$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_KEYS=""
if [ -f Resources/sparkle-public-key.txt ]; then
  SPARKLE_KEYS="<key>SUFeedURL</key><string>${FEED_URL:-https://pocketcoder.github.io/spring/nightly-appcast.xml}</string>
  <key>SUPublicEDKey</key><string>$(tr -d '[:space:]' < Resources/sparkle-public-key.txt)</string>
  <key>SUEnableInstallerLauncherService</key><true/>
  <key>SUEnableAutomaticChecks</key><true/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Spring</string>
  <key>CFBundleDisplayName</key><string>Spring</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Spring</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  ${SPARKLE_KEYS}
</dict>
</plist>
PLIST

# Sandboxed, with the mach-lookup exceptions Sparkle's installer service needs.
ENT="$(mktemp)"
cat > "$ENT" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
  <array><string>${BUNDLE_ID}-spks</string><string>${BUNDLE_ID}-spki</string></array>
</dict>
</plist>
XML

ID="${SIGN_IDENTITY:--}"
# Hardened runtime (library validation) only with a real identity: ad-hoc signatures carry no Team ID, so dyld
# would refuse the embedded Sparkle.framework.
RUNTIME=(); [ "$ID" != "-" ] && RUNTIME=(-o runtime)
S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign -f -s "$ID" -o runtime "$S/XPCServices/Installer.xpc"
codesign -f -s "$ID" -o runtime --preserve-metadata=entitlements "$S/XPCServices/Downloader.xpc"
codesign -f -s "$ID" -o runtime "$S/Autoupdate" "$S/Updater.app"
codesign -f -s "$ID" -o runtime "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements "$ENT" --sign "$ID" "$APP"
rm -f "$ENT"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION)"
