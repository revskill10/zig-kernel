import { afterAll, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdir, realpath, rm, writeFile } from "node:fs/promises";
import { isAbsolute, join, resolve, sep } from "node:path";
import { gunzipSync } from "node:zlib";
import { processAlive } from "../src/transports/helper.ts";

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
  if (!isAbsolute(candidate)) throw new Error("helper fallback is not absolute");
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
): Promise<string> {
  if (!stream || typeof stream === "number" || typeof stream.getReader !== "function") return "";
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
  return new TextDecoder().decode(out);
}

async function runOwned(
  cmd: string[],
  cwd: string,
  env: Record<string, string>,
  timeoutMs = 30_000,
  maxBytes = 256 * 1024,
): Promise<{ stdout: string; stderr: string; code: number; pid: number }> {
  const proc = Bun.spawn(cmd, {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
    windowsHide: true,
    env,
  });
  const pid = proc.pid;
  if (pid > 0) live.add(pid);
  const deadline = Date.now() + timeoutMs;
  const stdoutP = readBounded(proc.stdout, maxBytes, deadline);
  const stderrP = readBounded(proc.stderr, maxBytes, deadline);
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
    const [stdout, stderr, code] = await boundedRace(
      Promise.all([stdoutP, stderrP, proc.exited]),
      timeoutMs,
      `operation_timeout pid=${pid}`,
    );
    await reap(false);
    return { stdout, stderr, code, pid };
  } catch (err) {
    const reaped = await reap(true);
    if (!reaped) {
      const wrapped = err instanceof Error ? err : new Error(String(err));
      throw new Error(`${wrapped.message}; unreaped pid=${pid}`);
    }
    throw err;
  }
}

function listTarEntries(gzipped: Uint8Array): string[] {
  const buf = gunzipSync(gzipped);
  const names: string[] = [];
  let offset = 0;
  while (offset + 512 <= buf.byteLength) {
    const block = buf.subarray(offset, offset + 512);
    if (block.every((b) => b === 0)) break;
    const name = new TextDecoder().decode(block.subarray(0, 100)).replace(/\0.*$/, "");
    const prefix = new TextDecoder().decode(block.subarray(345, 500)).replace(/\0.*$/, "");
    const sizeOct = new TextDecoder().decode(block.subarray(124, 136)).replace(/\0.*$/, "").trim();
    const size = Number.parseInt(sizeOct, 8) || 0;
    const full = prefix ? `${prefix}/${name}` : name;
    if (full) names.push(full.replace(/\\/g, "/"));
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  return names;
}

function allowedEntry(name: string): boolean {
  const n = name.replace(/\\/g, "/");
  const body = n.startsWith("package/") ? n.slice("package/".length) : n;
  if (body === "package.json" || body === "README.md") return true;
  if (body.startsWith("dist/") && (body.endsWith(".js") || body.endsWith(".d.ts"))) return true;
  return false;
}

function tarballIntegrity(bytes: Uint8Array): string {
  return `sha512-${new Bun.CryptoHasher("sha512").update(bytes).digest("base64")}`;
}

function withSdkFileDependencyLock(lockText: string, fileSpec: string, lockSpec: string, integrity: string): string {
  const normalized = lockText.replaceAll("\r\n", "\n");
  const withWorkspace = normalized.replace(
    `      "devDependencies": {`,
    `      "dependencies": {\n        "@zig-sandbox/sdk": "${fileSpec}",\n      },\n      "devDependencies": {`,
  );
  const withPackage = withWorkspace.replace(
    `  "packages": {\n`,
    `  "packages": {\n    "@zig-sandbox/sdk": ["@zig-sandbox/sdk@${lockSpec}", {}, "${integrity}"],\n\n`,
  );
  if (!withPackage.includes(fileSpec) || !withPackage.includes(`"@zig-sandbox/sdk@${lockSpec}"`) || !withPackage.includes(integrity)) {
    throw new Error("failed to record SDK file dependency in frozen toolchain lock");
  }
  return withPackage;
}

function filterEnv(env: NodeJS.ProcessEnv): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) continue;
    if (/^(DOCKER_HOST|SSH_|AWS_|GOOGLE_|AZURE_)/i.test(key)) continue;
    out[key] = value;
  }
  return out;
}

const testRoot = requireTestRoot();
const scratch = await acquireExclusiveDir(testRoot, "package-pack");
const pkgRoot = resolve(import.meta.dir, "..");
const bun = process.execPath;

afterAll(async () => {
  await releaseExclusiveDir(scratch, [...live]);
});

describe("withSdkFileDependencyLock", () => {
  test("LF and CRLF lock text yield equivalent insertions", () => {
    const fileSpec = "file:../pack/zig-sandbox-sdk-0.1.0-ts0.tgz";
    const lockSpec = "../pack/zig-sandbox-sdk-0.1.0-ts0.tgz";
    const integrity = "sha512-fixture";
    const lockLf = [
      "{",
      `  "lockfileVersion": 1,`,
      `  "workspaces": {`,
      `    "": {`,
      `      "name": "sdk-consumer",`,
      `      "devDependencies": {`,
      `        "typescript": "7.0.2"`,
      "      }",
      "    }",
      "  },",
      `  "packages": {`,
      `    "typescript": ["typescript@7.0.2", {}, "sha512-abc"]`,
      "  }",
      "}",
      "",
    ].join("\n");
    const lockCrlf = lockLf.replaceAll("\n", "\r\n");
    expect(lockCrlf).toContain("\r\n");
    expect(lockLf).not.toContain("\r");
    const fromLf = withSdkFileDependencyLock(lockLf, fileSpec, lockSpec, integrity);
    const fromCrlf = withSdkFileDependencyLock(lockCrlf, fileSpec, lockSpec, integrity);
    expect(fromLf).toBe(fromCrlf);
    expect(fromLf).toContain(fileSpec);
    expect(fromLf).toContain(`"@zig-sandbox/sdk@${lockSpec}"`);
    expect(fromLf).toContain(integrity);
    expect(fromLf).not.toContain("\r");
  });
});

describe("packed tarball consumer", () => {
  test("bun pack, frozen toolchain, bun file-dependency install, import local, and declaration typecheck", async () => {
    const packDir = join(scratch, "pack");
    const consumer = join(scratch, "consumer");
    await mkdir(packDir, { recursive: true });
    await mkdir(consumer, { recursive: true });

    const env = {
      ...filterEnv(process.env),
      TMP: scratch,
      TEMP: scratch,
      TMPDIR: scratch,
      BUN_INSTALL_CACHE_DIR: process.env.BUN_INSTALL_CACHE_DIR ?? join(testRoot, "bun-cache"),
      npm_config_cache: process.env.npm_config_cache ?? join(testRoot, "npm-cache"),
    };

    const build = await runOwned([bun, "run", "build"], pkgRoot, env);
    if (build.code !== 0) throw new Error(`build exit ${build.code}\nstdout:${build.stdout}\nstderr:${build.stderr}`);
    expect(existsSync(join(pkgRoot, "dist", "index.d.ts"))).toBe(true);
    expect(existsSync(join(pkgRoot, "dist", "local.d.ts"))).toBe(true);

    const packed = await runOwned(
      [bun, "pm", "pack", "--cwd", pkgRoot, "--destination", packDir, "--ignore-scripts"],
      scratch,
      env,
    );
    if (packed.code !== 0) throw new Error(`pack exit ${packed.code}\nstdout:${packed.stdout}\nstderr:${packed.stderr}`);
    const tgz = join(packDir, "zig-sandbox-sdk-0.1.0-ts0.tgz");
    expect(existsSync(tgz)).toBe(true);

    const tarBytes = new Uint8Array(await Bun.file(tgz).arrayBuffer());
    const entries = listTarEntries(tarBytes);
    expect(entries.length).toBeGreaterThan(3);
    for (const entry of entries) {
      expect(allowedEntry(entry)).toBe(true);
    }
    expect(entries.some((e) => e.replace(/\\/g, "/").endsWith("package.json"))).toBe(true);
    expect(entries.some((e) => /dist\/index\.d\.ts$/.test(e.replace(/\\/g, "/")))).toBe(true);

    const helper = helperPath();
    const sdkLockSpec = "../pack/zig-sandbox-sdk-0.1.0-ts0.tgz";
    const sdkFileSpec = `file:${sdkLockSpec}`;
    const lockText = (await Bun.file(join(pkgRoot, "bun.lock")).text()).replace(
      '"name": "@zig-sandbox/sdk"',
      '"name": "sdk-consumer"',
    );
    if (!lockText.includes('"name": "sdk-consumer"')) {
      throw new Error("failed to adapt frozen toolchain lock name");
    }
    const lockWithSdk = withSdkFileDependencyLock(lockText, sdkFileSpec, sdkLockSpec, tarballIntegrity(tarBytes));
    const consumerPkg = {
      name: "sdk-consumer",
      private: true,
      type: "module",
      dependencies: {
        "@zig-sandbox/sdk": sdkFileSpec,
      },
      devDependencies: {
        "@types/bun": "1.4.2",
        typescript: "7.0.2",
      },
    };
    await writeFile(join(consumer, "package.json"), JSON.stringify(consumerPkg, null, 2));
    await writeFile(join(consumer, "bun.lock"), lockWithSdk);
    await writeFile(
      join(consumer, "run.ts"),
      `import { LocalSandbox } from "@zig-sandbox/sdk/local";
import { SandboxUnavailableError } from "@zig-sandbox/sdk";
const runtime = await LocalSandbox.open({ helperPath: ${JSON.stringify(helper)}, cwd: ${JSON.stringify(consumer)} });
try {
  const caps = await runtime.capabilities();
  if (caps.features.execution !== false) throw new Error("execution must be false");
  let unavailable = false;
  try { await runtime.create({ profile: "linux-vm/x64", image: { id: "example", digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" } }); }
  catch (e) { if (e instanceof SandboxUnavailableError) unavailable = true; else throw e; }
  if (!unavailable) throw new Error("create did not reject");
  console.log(JSON.stringify({ ok: true, execution: caps.features.execution }));
} finally {
  await runtime.close();
}
`,
    );
    await writeFile(
      join(consumer, "types-check.ts"),
      `import { SandboxUnavailableError, SDK_PACKAGE_VERSION } from "@zig-sandbox/sdk";
import { RemoteSandbox } from "@zig-sandbox/sdk/remote";
import { LocalSandbox } from "@zig-sandbox/sdk/local";
const _e: typeof SandboxUnavailableError = SandboxUnavailableError;
const _v: string = SDK_PACKAGE_VERSION;
type _R = RemoteSandbox;
type _L = typeof LocalSandbox.open;
void _e; void _v; type _Keep = [_R, _L];
`,
    );
    await writeFile(
      join(consumer, "tsconfig.json"),
      JSON.stringify(
        {
          compilerOptions: {
            target: "ES2022",
            module: "NodeNext",
            moduleResolution: "NodeNext",
            strict: true,
            types: ["bun"],
            skipLibCheck: true,
            noEmit: true,
          },
          files: ["types-check.ts"],
        },
        null,
        2,
      ),
    );

    const install = await runOwned([bun, "install", "--frozen-lockfile", "--ignore-scripts"], consumer, env);
    if (install.code !== 0) throw new Error(`install exit ${install.code}\nstdout:${install.stdout}\nstderr:${install.stderr}`);
    expect(install.stdout).toContain("@zig-sandbox/sdk@../pack/zig-sandbox-sdk-0.1.0-ts0.tgz");

    const recorded = JSON.parse(await Bun.file(join(consumer, "package.json")).text()) as {
      dependencies?: Record<string, string>;
      devDependencies?: Record<string, string>;
    };
    expect(recorded.dependencies?.["@zig-sandbox/sdk"]).toBe(sdkFileSpec);
    expect(recorded.devDependencies?.["@types/bun"]).toBe("1.4.2");
    expect(recorded.devDependencies?.typescript).toBe("7.0.2");

    const lockAfterInstall = await Bun.file(join(consumer, "bun.lock")).text();
    expect(lockAfterInstall.includes(sdkFileSpec)).toBe(true);
    expect(lockAfterInstall.includes('"typescript": "7.0.2"')).toBe(true);
    expect(lockAfterInstall.includes('"@types/bun": "1.4.2"')).toBe(true);

    const installedSdk = join(consumer, "node_modules", "@zig-sandbox", "sdk");
    expect(existsSync(join(installedSdk, "package.json"))).toBe(true);
    expect(existsSync(join(installedSdk, "dist", "local.d.ts"))).toBe(true);

    const frozenRepeat = await runOwned([bun, "install", "--frozen-lockfile", "--ignore-scripts"], consumer, env);
    if (frozenRepeat.code !== 0) {
      throw new Error(`frozen repeat exit ${frozenRepeat.code}\nstdout:${frozenRepeat.stdout}\nstderr:${frozenRepeat.stderr}`);
    }
    const lockAfterRepeat = await Bun.file(join(consumer, "bun.lock")).text();
    expect(lockAfterRepeat.includes(sdkFileSpec)).toBe(true);
    expect(lockAfterRepeat.includes('"typescript": "7.0.2"')).toBe(true);
    expect(lockAfterRepeat.includes('"@types/bun": "1.4.2"')).toBe(true);
    expect(existsSync(join(installedSdk, "package.json"))).toBe(true);
    expect(existsSync(join(installedSdk, "dist", "local.d.ts"))).toBe(true);

    const runResult = await runOwned([bun, "run.ts"], consumer, env, 20_000);
    if (runResult.code !== 0) throw new Error(`consumer exit ${runResult.code}\nstdout:${runResult.stdout}\nstderr:${runResult.stderr}`);
    expect(runResult.stdout).toContain('"execution":false');

    const tsc = join(consumer, "node_modules", "typescript", "bin", "tsc");
    const typecheck = await runOwned([bun, tsc, "-p", "tsconfig.json", "--pretty", "false"], consumer, env);
    if (typecheck.code !== 0) throw new Error(`tsc exit ${typecheck.code}\nstdout:${typecheck.stdout}\nstderr:${typecheck.stderr}`);
  });
});
