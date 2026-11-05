#!/bin/bash
# Native Zig 0.17.1 regression on this Mac (Debug + ReleaseFast).
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$ROOT/artifacts/macos-local/zig"
mkdir -p "$LOG"
export PATH="${ZIG_BIN:-$ROOT/.zig-0.17.1}:$PATH"
cd "$ROOT"
got="$(zig version)"
echo "zig=$got"
if [ "$got" != "0.17.1" ]; then
  echo "ERROR: need official Zig 0.17.1, got $got"
  echo "official: https://ziglang.org/download/ (2026-11-02)"
  echo "run ./scripts/macos/install-zig-0.17.1.sh"
  exit 1
fi
{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git_sha=$(git rev-parse HEAD)"
  echo "uname=$(uname -a)"
  echo "zig=$(zig version)"
} | tee "$LOG/regression-env.txt"

echo "=== Debug ===" | tee "$LOG/regression.txt"
zig build test 2>&1 | tee -a "$LOG/regression.txt"
echo "=== ReleaseFast ===" | tee -a "$LOG/regression.txt"
zig build --release=fast
for g in rc perceus incremental epoch; do
  echo "--- gc-test-$g ---" | tee -a "$LOG/regression.txt"
  ./zig-out/bin/gc-test-$g 2>&1 | tee -a "$LOG/regression.txt"
done
echo "zig regression complete. Log: $LOG/regression.txt"
