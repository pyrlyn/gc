#!/bin/bash
# Install official Zig 0.17.1 for this Mac (aarch64 or x86_64).
# Source: https://ziglang.org/download/  (Latest Stable Version 0.17.1, 2026-11-02)
# Does not download master / 0.18.0-dev.
# mise may already have 0.17.0 or 0.16.0; those are not 0.17.1. This script
# installs 0.17.1 itself and refuses any other version.
#
# curl: HTTPS-only, including redirects (Sonar AaGuAJycRUAgjXuXSY55).
# Tests use POSIX `[` with quoted operands (bash shebang; no `[[`, so `sh` is safe).
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${ZIG_PREFIX:-$ROOT/.zig-0.17.1}"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64)
    TRIPLE=aarch64-macos
    SHA256=75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d
    ;;
  x86_64)
    TRIPLE=x86_64-macos
    SHA256=9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7
    ;;
  *) echo "unsupported uname -m: $ARCH (need arm64 or x86_64)"; exit 1 ;;
esac
VER=0.17.1
TARBALL="zig-${TRIPLE}-${VER}.tar.xz"
URL="https://ziglang.org/download/${VER}/${TARBALL}"
mkdir -p "$DEST"
if [ ! -x "$DEST/zig" ]; then
  echo "downloading official $URL"
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fL \
    -o "$DEST/$TARBALL" "$URL"
  echo "${SHA256}  $DEST/$TARBALL" | shasum -a 256 -c -
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
echo "sha256_checked=$SHA256"
