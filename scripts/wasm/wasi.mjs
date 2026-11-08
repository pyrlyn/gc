// Minimal WASI preview1 host for the wasm32-wasi GC binaries, in plain JS: no `node:wasi`, so the same
// module runs in Node, Bun, Deno and browsers. It implements what the collectors, tests and benches use
// (args, env, monotonic/realtime clocks, stdout/stderr, exit, random); file system calls report ENOSYS.
//
//   import { runWasi } from "./wasi.mjs";
//   const code = await runWasi(bytes, { args: ["gc-cycles", "100000"], env: { KX_GC_BUDGET_US: "500" } });

const ESUCCESS = 0, EBADF = 8, ENOSYS = 52, ESPIPE = 70;

export class WasiExit extends Error {
  constructor(code) {
    super(`wasi exit ${code}`);
    this.code = code;
  }
}

// Monotonic nanoseconds. performance.now() is coarsened in browsers (5 us .. 100 us); the collector's
// time budget only needs it to be monotonic, so prefer process.hrtime where a JS runtime has it.
const hr = globalThis.process?.hrtime?.bigint;
const nowNs = hr ? () => hr() : () => BigInt(Math.round(performance.now() * 1e6));
const resNs = hr ? 1n : 1000n;

function lineWriter(sink) {
  const dec = new TextDecoder();
  let buf = "";
  return {
    write(bytes) {
      buf += dec.decode(bytes, { stream: true });
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        sink(buf.slice(0, i));
        buf = buf.slice(i + 1);
      }
    },
    flush() {
      if (buf) sink(buf);
      buf = "";
    },
  };
}

export function wasiImports({ args = [], env = {}, stdout = console.log, stderr = console.error } = {}) {
  const enc = new TextEncoder();
  const argv = args.map((a) => enc.encode(a + "\0"));
  const envv = Object.entries(env).map(([k, v]) => enc.encode(`${k}=${v}\0`));
  const out = { 1: lineWriter(stdout), 2: lineWriter(stderr) };
  let memory = null;
  const dv = () => new DataView(memory.buffer);
  const u8 = () => new Uint8Array(memory.buffer);

  const strings = (list, ptrs, buf) => {
    const view = dv(), mem = u8();
    for (const s of list) {
      view.setUint32(ptrs, buf, true);
      mem.set(s, buf);
      ptrs += 4;
      buf += s.length;
    }
    return ESUCCESS;
  };
  const sizes = (list, countPtr, sizePtr) => {
    dv().setUint32(countPtr, list.length, true);
    dv().setUint32(sizePtr, list.reduce((n, s) => n + s.length, 0), true);
    return ESUCCESS;
  };

  const imports = {
    args_get: (p, b) => strings(argv, p, b),
    args_sizes_get: (c, s) => sizes(argv, c, s),
    environ_get: (p, b) => strings(envv, p, b),
    environ_sizes_get: (c, s) => sizes(envv, c, s),
    clock_res_get: (_id, out) => (dv().setBigUint64(out, resNs, true), ESUCCESS),
    clock_time_get: (id, _precision, out) => {
      const t = id === 0 ? BigInt(Date.now()) * 1_000_000n : nowNs();
      dv().setBigUint64(out, t, true);
      return ESUCCESS;
    },
    fd_write: (fd, iovs, iovsLen, nwritten) => {
      const w = out[fd];
      if (!w) return EBADF;
      const view = dv();
      let n = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovs + i * 8, true);
        const len = view.getUint32(iovs + i * 8 + 4, true);
        w.write(new Uint8Array(memory.buffer, ptr, len));
        n += len;
      }
      view.setUint32(nwritten, n, true);
      return ESUCCESS;
    },
    fd_fdstat_get: (fd, out) => {
      if (fd > 2) return EBADF;
      const view = dv();
      for (let i = 0; i < 24; i++) view.setUint8(out + i, 0);
      view.setUint8(out, 2); // character device
      return ESUCCESS;
    },
    fd_prestat_get: () => EBADF, // no preopened directories
    fd_close: (fd) => (fd <= 2 ? ESUCCESS : EBADF),
    fd_seek: () => ESPIPE, // stdio is not seekable
    random_get: (ptr, len) => {
      crypto.getRandomValues(new Uint8Array(memory.buffer, ptr, len));
      return ESUCCESS;
    },
    proc_exit: (code) => {
      throw new WasiExit(code);
    },
    poll_oneoff: () => ENOSYS,
    sched_yield: () => ESUCCESS,
  };
  const wasi = new Proxy(imports, {
    get: (t, name) => t[name] ?? (() => (typeof name === "string" && name.startsWith("fd_") ? EBADF : ENOSYS)),
  });
  return {
    imports: { wasi_snapshot_preview1: wasi },
    bind(instance) {
      memory = instance.exports.memory;
    },
    flush() {
      out[1].flush();
      out[2].flush();
    },
  };
}

/** Instantiates a wasm32-wasi command and runs `_start`; resolves to its exit code. */
export async function runWasi(bytes, opts = {}) {
  const host = wasiImports(opts);
  const { instance } = await WebAssembly.instantiate(bytes, host.imports);
  host.bind(instance);
  try {
    instance.exports._start();
    return 0;
  } catch (e) {
    if (e instanceof WasiExit) return e.code;
    throw e;
  } finally {
    host.flush();
  }
}
