#!/usr/bin/env bash
# Build the Linux one-file binary inside Docker (works from macOS/Windows hosts).
#   bash packaging/build-linux.sh [arm64|x64]     (x64 on Apple Silicon runs under emulation: slow but works)
# manylinux_2_28 base (glibc 2.28) → runs on Ubuntu 20.04+, Debian 10+, RHEL/Alma 8+ and newer distros.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ARCH="${1:-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/x64/')}"
if [ "$ARCH" = "x64" ]; then PLATFORM=linux/amd64; IMAGE=quay.io/pypa/manylinux_2_28_x86_64; else PLATFORM=linux/arm64; IMAGE=quay.io/pypa/manylinux_2_28_aarch64; fi
docker run --rm --platform "$PLATFORM" -v "$PWD":/src -w /src "$IMAGE" bash -euc '
  (cd /opt/_internal && tar xf static-libs-for-embedding-only.tar.xz)  # static libpython for embedding (Nuitka)
  PY=/opt/python/cp312-cp312/bin/python
  $PY -m venv /tmp/v
  /tmp/v/bin/pip -q install --upgrade pip
  /tmp/v/bin/pip -q install . nuitka ordered-set zstandard secretstorage
  /tmp/v/bin/python packaging/build.py
  ./dist/rowbase-linux-'"$ARCH"' doctor'
