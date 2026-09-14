import { afterAll, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdir, realpath, rm } from "node:fs/promises";
import { isAbsolute, join, resolve, sep } from "node:path";
import { HelperClosedError, HelperStartupError, HelperVersionError, SandboxUnavailableError } from "../src/errors.ts";
import { LocalSandbox, type LocalEngineTransport } from "../src/local.ts";
import { processAlive } from "../src/transports/helper.ts";
import {
  DIAGNOSTIC_EMPTY_CAPABILITIES,
  SDK_HELPER_NAME,
  SDK_HELPER_PROTOCOL,
  SDK_HELPER_VERSION,
  isCanonicalEnvelope,
  isDiagnosticEnvelope,
} from "../src/types.ts";

function requireTestRoot(): string {
  const raw = process.env.SANDBOX_SDK_TEST_ROOT;
  if (!raw) throw new Error("SANDBOX_SDK_TEST_ROOT is required so tests do not use inherited TEMP");
  const resolved = resolve(raw);
  if (!isAbsolute(resolved)) throw new Error("SANDBOX_SDK_TEST_ROOT must be absolute");
  if (process.platform === "win32" && !/^[Dd]:[\\/]/.test(resolved)) {
    throw new Error(`Windows test temp root must be on D:, got ${resolved}`);
  }
  return resolved;
}

function contained(root: string, candidate: string): boolean {
  const nroot = process.platform === "win32" ? root.toLowerCase() : root;
  const n = process.platform === "win32" ? candidate.toLowerCase() : candidate;
  return n === nroot || n.startsWith(nroot.endsWith(sep) ? nroot : nroot + sep);
}

async function acquireExclusiveDir(root: string, prefix: string): Promise<string> {
  await mkdir(root, { recursive: true });
  const rootReal = await realpath(root);
  const dir = join(rootReal, `${prefix}-${crypto.randomUUID()}`);
  const resolved = resolve(dir);
  if (!contained(rootReal, resolved)) throw new Error("scratch escaped test root");
  await mkdir(resolved);
  await Bun.write(join(resolved, ".sandbox-sdk-test"), `${process.pid}\n${resolved}\n`);
  const real = await realpath(resolved);
  if (!contained(rootReal, real)) throw new Error("resolved scratch escaped test root");
  return real;
}

async function releaseExclusiveDir(dir: string, unreaped: number[]): Promise<void> {
  for (const pid of unreaped) {
    if (pid > 0 && processAlive(pid)) {
      throw new Error(`refusing to delete ${dir}; pid ${pid} still live`);
    }
  }
  const real = await realpath(dir);
  if (!(await Bun.file(join(real, ".sandbox-sdk-test")).exists())) {
    throw new Error("refusing to delete directory without ownership marker");
  }
  await rm(real, { recursive: true, force: true });
}

function helperPath(): string {
  const fromEnv = process.env.ZIG_SANDBOX_HELPER;
  if (fromEnv) {
    if (!isAbsolute(fromEnv)) throw new Error("ZIG_SANDBOX_HELPER must be absolute");
    if (!existsSync(fromEnv)) throw new Error(`ZIG_SANDBOX_HELPER missing: ${fromEnv}`);
    return fromEnv;
  }
  const repo = resolve(import.meta.dir, "..", "..", "..", "..");
  const name = process.platform === "win32" ? "zig-sandbox-helper.exe" : "zig-sandbox-helper";
  const candidate = join(repo, "zig-out", "bin", name);
  if (!existsSync(candidate) || !isAbsolute(candidate)) {
    throw new Error(`compiled helper missing at ${candidate}; build sandbox-helper first`);
  }
  return candidate;
}

const CLEANUP_MS = 5_000;
const live = new Set<number>();

async function boundedRace<T>(work: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(label)), ms);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

async function readBounded(
  stream: ReadableStream<Uint8Array> | number | undefined,
  max: number,
  deadline: number,
): Promise<Uint8Array> {
  if (!stream || typeof stream === "number" || typeof stream.getReader !== "function") return new Uint8Array();
  const reader = stream.getReader();
  const parts: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const remain = Math.max(1, deadline - Date.now());
      const next = await boundedRace(reader.read(), remain, "read_deadline");
      if (next.done) break;
      size += next.value.byteLength;
      if (size > max) throw new Error("output exceeded bound");
      parts.push(next.value);
    }
  } finally {
    await Promise.race([
      Promise.resolve(reader.cancel()).catch(() => undefined),
      new Promise<void>((resolve) => setTimeout(resolve, 1000)),
    ]);
  }
  const out = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.byteLength;
  }
  return out;
}

async function runOwned(
  cmd: string[],
  opts: { cwd: string; env?: Record<string, string>; timeoutMs: number; maxBytes: number },
): Promise<{ code: number; stdout: Uint8Array; stderr: Uint8Array; pid: number }> {
  const proc = Bun.spawn(cmd, {
    cwd: opts.cwd,
    env: opts.env,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    windowsHide: true,
  });
  const pid = proc.pid;
  if (pid > 0) live.add(pid);
  const deadline = Date.now() + opts.timeoutMs;
  const stdoutP = readBounded(proc.stdout, opts.maxBytes, deadline);
  const stderrP = readBounded(proc.stderr, opts.maxBytes, deadline);
  stdoutP.catch(() => undefined);
  stderrP.catch(() => undefined);

  const reap = async (kill: boolean): Promise<boolean> => {
    if (kill && proc.exitCode === null) {
      try {
        proc.kill();
      } catch {
        // already exiting
      }
    }
    const reaped = await Promise.race([
      proc.exited.then(() => true),
      new Promise<false>((resolve) => setTimeout(() => resolve(false), CLEANUP_MS)),
    ]);
    if (reaped) live.delete(pid);
    return reaped;
  };

  try {
    if (proc.stdin && typeof proc.stdin !== "number") proc.stdin.end();
    const [stdout, stderr, code] = await boundedRace(
      Promise.all([stdoutP, stderrP, proc.exited]),
      opts.timeoutMs,
      `operation_timeout pid=${pid}`,
    );
    await reap(false);
    return { code, stdout, stderr, pid };
  } catch (err) {
    const reaped = await reap(true);
    if (!reaped) {
      const wrapped = err instanceof Error ? err : new Error(String(err));
      throw new Error(`${wrapped.message}; unreaped pid=${pid}`);
    }
    throw err;
  }
}

const testRoot = requireTestRoot();
const scratch = await acquireExclusiveDir(testRoot, "local-test");
const helper = helperPath();
const openOpts = { helperPath: helper, cwd: scratch, requestTimeoutMs: 3000, startupTimeoutMs: 5000, shutdownTimeoutMs: 3000 };

afterAll(async () => {
  await releaseExclusiveDir(scratch, [...live]);
});

describe("real compiled helper integration", () => {
  test("open, capabilities, create unavailable, close twice, reaped, no workload", async () => {
    const runtime = await LocalSandbox.open(openOpts);
    const pid = runtime.helperPid;
    expect(pid).toBeGreaterThan(0);
    live.add(pid!);
    try {
      expect(processAlive(pid!)).toBe(true);
      expect(runtime.helloInfo?.helper).toBe(SDK_HELPER_NAME);
      expect(runtime.helloInfo?.helper_version).toBe(SDK_HELPER_VERSION);
      expect(Object.isFrozen(runtime.helloInfo)).toBe(true);
      expect(() => {
        (runtime.helloInfo as { helper: string }).helper = "mutated";
      }).toThrow();
      const caps = await runtime.capabilities();
      expect(caps.features.execution).toBe(false);
      expect(caps).toEqual(DIAGNOSTIC_EMPTY_CAPABILITIES);
      expect(Object.isFrozen(caps.features)).toBe(true);
      expect(() => {
        caps.features.execution = true;
      }).toThrow();
      expect((await runtime.capabilities()).features.execution).toBe(false);
      const health = await runtime.health();
      expect(health.status).toBe("ok");
      const ready = await runtime.ready();
      expect(ready.status).toBe(503);
      expect(ready.document.reason).toBe("execution_unavailable");
      let createErr: unknown;
      try {
        await runtime.create({
          profile: "linux-vm/x64",
          image: { id: "example", digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" },
        });
      } catch (err) {
        createErr = err;
      }
      expect(createErr).toBeInstanceOf(SandboxUnavailableError);
      const unavailable = createErr as SandboxUnavailableError;
      expect(unavailable.provenance).toBe("helper");
      expect(unavailable.httpStatus).toBe(501);
      expect(unavailable.diagnostic.error.code).toBe("execution_unavailable");
      expect(isDiagnosticEnvelope(JSON.stringify(unavailable.diagnostic))).toBe(true);
      expect(isCanonicalEnvelope(JSON.stringify(unavailable.diagnostic))).toBe(false);
      expect(JSON.stringify(unavailable.diagnostic).includes("request_id")).toBe(false);
      let execErr: unknown;
      try {
        await runtime.exec();
      } catch (err) {
        execErr = err;
      }
      expect(execErr).toBeInstanceOf(SandboxUnavailableError);
      expect((execErr as SandboxUnavailableError).provenance).toBe("local");
    } finally {
      try {
        await runtime.close();
        await runtime.close();
      } finally {
        if (pid && processAlive(pid)) live.add(pid);
        else if (pid) live.delete(pid);
      }
    }
    expect(runtime.helperPid).toBeNull();
    expect(processAlive(pid!)).toBe(false);
  });

  test("startup abort does not leave a helper", async () => {
    const controller = new AbortController();
    controller.abort();
    let err: unknown;
    try {
      await LocalSandbox.open({ ...openOpts, signal: controller.signal });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(HelperClosedError);
    expect((err as HelperClosedError).code).toBe("aborted");
  });

  test("abort during open fails closed and reaps", async () => {
    const controller = new AbortController();
    const pending = LocalSandbox.open({ ...openOpts, signal: controller.signal, startupTimeoutMs: 5000 });
    controller.abort();
    let err: unknown;
    try {
      await pending;
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(HelperClosedError);
  });

  test("parent stdin EOF causes helper exit", async () => {
    const result = await runOwned([helper], {
      cwd: scratch,
      timeoutMs: 5000,
      maxBytes: 64 * 1024,
      env: process.platform === "win32"
        ? { SYSTEMROOT: process.env.SYSTEMROOT ?? "", WINDIR: process.env.WINDIR ?? "" }
        : {},
    });
    expect(result.code).toBe(0);
    expect(processAlive(result.pid)).toBe(false);
  });

  test("relative helperPath is rejected and does not spawn", async () => {
    let err: unknown;
    try {
      await LocalSandbox.open({ helperPath: "zig-sandbox-helper", cwd: scratch });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(HelperStartupError);
    expect(String(err)).toContain("absolute");
  });
});

const INJECTED_DIAG = {
  health: { status: "ok" },
  ready: { status: "not_ready", reason: "execution_unavailable" },
  capabilities: DIAGNOSTIC_EMPTY_CAPABILITIES,
  http: { health: 200, ready: 503, capabilities: 200 },
};

describe("injected transport hello contract", () => {
  test("empty hello is rejected and the injected transport is closed", async () => {
    let closed = 0;
    const fake: LocalEngineTransport = {
      state: "open",
      pid: null,
      lastPid: null,
      async open() {
        return {} as never;
      },
      async request() {
        return INJECTED_DIAG;
      },
      async close() {
        closed += 1;
      },
    };
    let err: unknown;
    try {
      await LocalSandbox.open({ transport: fake });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(HelperVersionError);
    expect((err as HelperVersionError).code).toBe("version_mismatch");
    expect(closed).toBe(1);
  });

  test("helloInfo is a frozen clone so callers cannot mutate internal data", async () => {
    const hello = {
      protocol: SDK_HELPER_PROTOCOL,
      contract_version: "1",
      api_version: "v1",
      helper: SDK_HELPER_NAME,
      helper_version: SDK_HELPER_VERSION,
    };
    const fake: LocalEngineTransport = {
      state: "open",
      pid: null,
      lastPid: null,
      async open() {
        return hello;
      },
      async request() {
        return INJECTED_DIAG;
      },
      async close() {
        return;
      },
    };
    const runtime = await LocalSandbox.open({ transport: fake });
    try {
      expect(runtime.helloInfo).toEqual(hello);
      expect(Object.isFrozen(runtime.helloInfo)).toBe(true);
      expect(() => {
        (runtime.helloInfo as { helper: string }).helper = "mutated";
      }).toThrow();
      hello.helper = "mutated-source";
      expect(runtime.helloInfo?.helper).toBe(SDK_HELPER_NAME);
    } finally {
      await runtime.close();
    }
  });
});
