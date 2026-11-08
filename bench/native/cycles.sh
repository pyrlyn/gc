#!/bin/sh
# One process per (collector, scenario) so pause max / p99 are per scenario.
#   bench/native/cycles.sh [N]                 native  (zig build --release=fast first)
#   RUNNER="node scripts/wasm/run.mjs" EXT=.wasm bench/native/cycles.sh [N]
#                                              wasm32-wasi (zig build --release=fast -Dtarget=wasm32-wasi)
set -eu
N="${1:-1000000}"
RUNNER="${RUNNER:-}"
EXT="${EXT:-}"
for s in garbage shared_1k shared_20k shared_200k; do
  for g in ${GCS:-perceus incremental}; do
    $RUNNER "zig-out/bin/gc-cycles-$g$EXT" "$N" "$s"
  done
done
