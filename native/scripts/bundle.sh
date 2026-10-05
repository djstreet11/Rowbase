#!/usr/bin/env bash
# Build dist/Rowbase.app (release). Signing: ROWBASE_SIGN_IDENTITY="Developer ID Application: …" → hardened runtime,
# timestamped, notarizable; otherwise ad-hoc (runs locally only).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
swift build -c release --arch arm64

APP="dist/Rowbase.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Rowbase "$APP/Contents/MacOS/Rowbase"
# Sparkle (auto-update): SwiftPM leaves the framework next to the binary; the bundle needs it in Frameworks/ + an rpath
mkdir -p "$APP/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
otool -l "$APP/Contents/MacOS/Rowbase" | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Rowbase"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Embedded CLI / MCP server (Python one-file build). Build it first: python packaging/build.py (repo root).
CLI="../dist/rowbase-macos-arm64"
if [[ -x "$CLI" ]]; then
  cp "$CLI" "$APP/Contents/Resources/rowbase"
else
  echo "warning: $CLI not found — app will ship without the MCP server (run: python packaging/build.py)" >&2
fi

# Owner's rule: ad-hoc builds ask before installing an update; Developer ID builds install silently (on quit/relaunch)
if [[ -n "${ROWBASE_SIGN_IDENTITY:-}" ]]; then AUTO_UPDATE="<true/>"; else AUTO_UPDATE="<false/>"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Rowbase</string>
  <key>CFBundleDisplayName</key><string>Rowbase</string>
  <key>CFBundleIdentifier</key><string>dev.rowbase.Rowbase</string>
  <key>CFBundleExecutable</key><string>Rowbase</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Sparkle auto-update (docs/UPDATES.md); public EdDSA key, private one = secret SPARKLE_ED_PRIVATE_KEY -->
  <key>SUFeedURL</key><string>https://github.com/djstreet11/Rowbase/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>UkOKTzt1PkcCC7qWiHHgHptn0b4yowWM392/i3/yVVo=</string>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUAutomaticallyUpdate</key>${AUTO_UPDATE}
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Rowbase</string>
</dict>
</plist>
PLIST

# Sign inside-out (never --deep): Sparkle's helpers, the framework, then the app. Hardened runtime only with a real identity.
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -n "${ROWBASE_SIGN_IDENTITY:-}" ]]; then SIGN=(--force --options runtime --timestamp --sign "$ROWBASE_SIGN_IDENTITY")
else SIGN=(--force --sign -); fi
codesign "${SIGN[@]}" "$SPK/XPCServices/Installer.xpc"
codesign "${SIGN[@]}" --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
codesign "${SIGN[@]}" "$SPK/Autoupdate" "$SPK/Updater.app"
codesign "${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "${ROWBASE_SIGN_IDENTITY:-}" ]]; then
  codesign "${SIGN[@]}" --entitlements Rowbase.entitlements "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  codesign "${SIGN[@]}" "$APP"
fi
echo "$(pwd)/$APP"
