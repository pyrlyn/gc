#!/bin/bash
# Install official Zig 0.17.1 for this Mac (aarch64 or x86_64).
# Source: https://ziglang.org/download/  (Latest Stable Version 0.17.1, 2026-11-02)
# Does not download master / 0.18.0-dev.
# mise may already have 0.17.0 or 0.16.0; those are not 0.17.1. This script
# installs 0.17.1 itself and refuses any other version.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${ZIG_PREFIX:-$ROOT/.zig-0.17.1}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) TRIPLE=aarch64-macos ;;
  x86_64) TRIPLE=x86_64-macos ;;
  *) echo "unsupported uname -m: $ARCH (need arm64 or x86_64)"; exit 1 ;;
esac
VER=0.17.1
TARBALL="zig-${TRIPLE}-${VER}.tar.xz"
URL="https://ziglang.org/download/${VER}/${TARBALL}"
mkdir -p "$DEST"
if [ ! -x "$DEST/zig" ]; then
  echo "downloading official $URL"
  curl -fL "$URL" -o "$DEST/$TARBALL"
  tar -xJf "$DEST/$TARBALL" -C "$DEST" --strip-components=1
fi
echo "zig=$DEST/zig"
"$DEST/zig" version
got="$("$DEST/zig" version)"
if [ "$got" != "$VER" ]; then
  echo "ERROR: expected official $VER, got $got (refusing a silent substitute)"
  exit 1
fi
echo "export PATH=\"$DEST:\$PATH\""
echo "official_source=https://ziglang.org/download/"
echo "official_date=2026-11-02"
echo "notes=https://ziglang.org/download/0.17.0/release-notes.html"
