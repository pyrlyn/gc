#!/usr/bin/env node
// Runs a wasm32-wasi GC binary under a JS engine through the plain-JS WASI host (wasi.mjs).
//   zig build --release=fast -Dtarget=wasm32-wasi
//   node scripts/wasm/run.mjs zig-out/bin/gc-test-incremental.wasm
//   bun  scripts/wasm/run.mjs zig-out/bin/gc-cycles-incremental.wasm 1000000 shared_1k
//   deno run --allow-read --allow-env scripts/wasm/run.mjs zig-out/bin/gc-ops-incremental.wasm
// KX_GC_* variables of the calling environment are passed through.
import { readFile } from "node:fs/promises";
import process from "node:process";
import { runWasi } from "./wasi.mjs";

const [file, ...rest] = process.argv.slice(2);
if (!file) {
  console.error("usage: run.mjs <program.wasm> [args...]");
  process.exit(2);
}
// `| head` closing the pipe ends the run quietly, as it does a native binary.
process.stdout.on("error", (e) => {
  if (e.code !== "EPIPE") throw e;
  process.exit(0);
});
const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => k.startsWith("KX_GC_")));
const name = file.split("/").pop().replace(/\.wasm$/, "");
const code = await runWasi(await readFile(file), {
  args: [name, ...rest],
  env,
  stdout: (l) => process.stdout.write(l + "\n"),
  stderr: (l) => process.stderr.write(l + "\n"),
});
process.exitCode = code;
