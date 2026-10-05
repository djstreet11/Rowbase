#!/usr/bin/env bash
# Release: app bundle → signed DMG → (optional) notarization + stapling; plus Rowbase-<v>.zip = Sparkle update payload.
#   ROWBASE_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"   (security find-identity -v -p codesigning)
#   ROWBASE_NOTARY_PROFILE  keychain profile created once with: xcrun notarytool store-credentials <profile> …
# Without them the DMG is ad-hoc signed: fine for your own Mac, Gatekeeper will warn on other Macs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

bash scripts/bundle.sh >/dev/null
VERSION="$(cat VERSION)"
DMG="dist/Rowbase-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# DMG content: the app + an Applications shortcut (drag to install) + volume icon
cp -R dist/Rowbase.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
rm -f "$DMG"
hdiutil create -volname "Rowbase ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "dist/rw.dmg" >/dev/null
# mark the volume as having a custom icon (attribute C), then compress
MNT="$(hdiutil attach -nobrowse -noverify -noautoopen "dist/rw.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')"
if command -v SetFile >/dev/null; then SetFile -a C "$MNT"; fi
hdiutil detach "$MNT" -quiet
hdiutil convert "dist/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "dist/rw.dmg"

if [[ -n "${ROWBASE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$ROWBASE_SIGN_IDENTITY" "$DMG"
  if [[ -n "${ROWBASE_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$ROWBASE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true
  else
    echo "note: ROWBASE_NOTARY_PROFILE not set — signed but not notarized" >&2
  fi
else
  echo "note: ROWBASE_SIGN_IDENTITY not set — ad-hoc signed DMG (local use only)" >&2
fi
# Update payload for Sparkle (docs/UPDATES.md): zipped app, ditto keeps the code signature and symlinks intact
ZIP="dist/Rowbase-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent dist/Rowbase.app "$ZIP"
ls -lh "$DMG" "$ZIP" | awk '{print $5, $NF}'
