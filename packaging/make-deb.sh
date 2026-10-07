#!/usr/bin/env bash
# Wrap the Linux one-file binary into a .deb (double-click → install in Ubuntu App Center, or `sudo apt install ./rowbase_*.deb`).
# Installs /usr/bin/rowbase + an app-menu entry "Rowbase" (opens the web UI). Needs dpkg-deb (any Debian/Ubuntu host).
#   bash packaging/make-deb.sh dist/rowbase-linux-x64 [x64|arm64]   → dist/rowbase_<version>_<amd64|arm64>.deb
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BIN="$1"; ARCH="${2:-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/x64/')}"
DEBARCH=$([ "$ARCH" = "x64" ] && echo amd64 || echo arm64)
VERSION="$(python3 -c 'import re;print(re.search(r"__version__\s*=\s*\"([^\"]+)\"", open("rowbase/__init__.py").read()).group(1))')"
ROOT="$(mktemp -d)"; chmod 755 "$ROOT"; trap 'rm -rf "$ROOT"' EXIT
install -Dm755 "$BIN" "$ROOT/usr/bin/rowbase"
install -Dm644 packaging/rowbase.desktop "$ROOT/usr/share/applications/rowbase.desktop"
install -Dm644 packaging/rowbase-256.png "$ROOT/usr/share/icons/hicolor/256x256/apps/rowbase.png"
install -Dm644 LICENSE "$ROOT/usr/share/doc/rowbase/copyright"
mkdir -p "$ROOT/DEBIAN"
cat > "$ROOT/DEBIAN/control" <<CTL
Package: rowbase
Version: $VERSION
Architecture: $DEBARCH
Maintainer: Rowbase <https://github.com/djstreet11/Rowbase>
Section: database
Priority: optional
Recommends: xdg-utils
Installed-Size: $(du -sk "$ROOT/usr" | cut -f1)
Homepage: https://github.com/djstreet11/Rowbase
Description: Fast, safe-by-default database client (MySQL, PostgreSQL, SQLite)
 Read-only by default. Local web UI with column filters and a visual query
 builder, a CLI for scripts and AI agents, and a built-in MCP server.
 Start "Rowbase" from the applications menu or run "rowbase" in a terminal.
CTL
mkdir -p dist
OUT="dist/rowbase_${VERSION}_${DEBARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$OUT" >/dev/null
echo "$OUT"
