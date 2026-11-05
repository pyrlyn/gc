#!/bin/bash
# Zig 0.17.1 ops on this Mac. Same N / interleaving as scripts/macos/c-baseline.sh.
# Writes artifacts/macos-local/zig/ — not the Linux VM zig-bench logs.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${ZIG_BIN:-$ROOT/.zig-0.17.1}:$PATH"
OUT="$ROOT/zig-out/bin"
LOG="$ROOT/artifacts/macos-local/zig/logs"
mkdir -p "$LOG"
cd "$ROOT"
got="$(zig version)"
if [ "$got" != "0.17.1" ]; then
  echo "ERROR: need official Zig 0.17.1, got $got (https://ziglang.org/download/ 2026-11-02)"
  exit 1
fi
zig version | tee "$LOG/zig-version.txt"
{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git_sha=$(git rev-parse HEAD)"
  echo "uname=$(uname -a)"
  echo "hw=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
  echo "ncpu=$(sysctl -n hw.ncpu)"
  echo "optimize=--release=fast"
  echo "lto=none-on-macho (Zig 0.17.1 self-hosted Mach-O linker has no LLVM LTO; ELF still uses -flto=full)"
} | tee "$LOG/environment.txt"

zig build --release=fast
GCS="perceus incremental epoch rc"
N=4000000
{
  echo "# start $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# N=$N"
  echo "## N=$N"
  for r in 1 2 3 4 5; do
    echo "# round $r"
    for g in $GCS; do
      "$OUT/gc-ops-$g" "$N" | sed "s/^[^ ]*/$g/"
    done
  done
  echo "# end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$LOG/ops-raw.txt"

{
  echo "# size sweep"
  for n in 100000 1000000 4000000; do
    echo "## N=$n"
    for r in 1 2 3; do
      for g in $GCS; do
        echo -n "N=$n round=$r "
        "$OUT/gc-ops-$g" "$n"
      done
    done
  done
} | tee "$LOG/ops-size-sweep.txt"

echo "macOS Zig ops complete. Logs in $LOG"
echo "If C ops-raw lives at ~/Grok/gc-local-bench/c-logs/ops-raw.txt, copy it to artifacts/macos-local/c/logs/ first."
echo "Compare with: python3 scripts/macos/compare.py --pair mac-local --label \"local Mac\""
