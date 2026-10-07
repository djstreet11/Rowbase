#!/bin/sh
# Rowbase for Linux without root: one-file binary → ~/.local/bin/rowbase + "Rowbase" in the applications menu.
#   curl -fsSL https://raw.githubusercontent.com/djstreet11/Rowbase/main/packaging/install.sh | sh
# Uninstall: rm ~/.local/bin/rowbase ~/.local/share/applications/rowbase.desktop ~/.local/share/icons/hicolor/256x256/apps/rowbase.png
set -eu
case "$(uname -m)" in x86_64|amd64) ARCH=x64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;; esac
[ "$(uname -s)" = Linux ] || { echo "This installer is for Linux; see https://github.com/djstreet11/Rowbase#install" >&2; exit 1; }
BASE="${ROWBASE_DOWNLOAD:-https://github.com/djstreet11/Rowbase/releases/latest/download}"
RAW="${ROWBASE_RAW:-https://raw.githubusercontent.com/djstreet11/Rowbase/main/packaging}"
BIN="$HOME/.local/bin"; APPS="$HOME/.local/share/applications"; ICONS="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$BIN" "$APPS" "$ICONS"
echo "Downloading rowbase-linux-$ARCH…"
curl -fL --progress-bar -o "$BIN/rowbase.new" "$BASE/rowbase-linux-$ARCH"
chmod +x "$BIN/rowbase.new"
"$BIN/rowbase.new" --version >/dev/null
mv -f "$BIN/rowbase.new" "$BIN/rowbase"
curl -fsSL -o "$ICONS/rowbase.png" "$RAW/rowbase-256.png" || true
curl -fsSL "$RAW/rowbase.desktop" | sed "s|^Exec=rowbase|Exec=$BIN/rowbase|" > "$APPS/rowbase.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true
echo "Installed $("$BIN/rowbase" --version). Start \"Rowbase\" from the applications menu, or run: rowbase"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Note: add $BIN to PATH to use the rowbase command in a terminal." ;; esac
