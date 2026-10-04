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
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Embedded CLI / MCP server (Python one-file build). Build it first: python packaging/build.py (repo root).
CLI="../dist/rowbase-macos-arm64"
if [[ -x "$CLI" ]]; then
  cp "$CLI" "$APP/Contents/Resources/rowbase"
else
  echo "warning: $CLI not found — app will ship without the MCP server (run: python packaging/build.py)" >&2
fi

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
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Rowbase</string>
</dict>
</plist>
PLIST

if [[ -n "${ROWBASE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements Rowbase.entitlements --sign "$ROWBASE_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  codesign --force -s - "$APP"
fi
echo "$(pwd)/$APP"
