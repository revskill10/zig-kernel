import { afterAll, describe, expect, test } from "bun:test";
import { mkdir, realpath, rm } from "node:fs/promises";
import { isAbsolute, join, resolve, sep } from "node:path";
import { LocalSandbox } from "../src/local.ts";
import { encodeFrame, OwnedHelperTransport, parseHelperResponse, processAlive } from "../src/transports/helper.ts";
import {
  HelperBusyError,
  HelperClosedError,
  HelperProtocolError,
  HelperStartupError,
  HelperVersionError,
  LocalRuntimeError,
} from "../src/errors.ts";
import { parseHelperHello, SDK_HELPER_NAME, SDK_HELPER_PROTOCOL, SDK_HELPER_VERSION } from "../src/types.ts";

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

const unhandled: unknown[] = [];
function onUnhandled(err: unknown): void {
  unhandled.push(err);
}
process.on("unhandledRejection", onUnhandled);

const testRoot = requireTestRoot();
const scratch = await acquireExclusiveDir(testRoot, "helper-fakes");
const bunPath = process.execPath;
const live = new Set<number>();

afterAll(async () => {
  process.off("unhandledRejection", onUnhandled);
  expect(unhandled).toEqual([]);
  await releaseExclusiveDir(scratch, [...live]);
});

const HELLO = {
  protocol: SDK_HELPER_PROTOCOL,
  contract_version: "1",
  api_version: "v1",
  helper: SDK_HELPER_NAME,
  helper_version: SDK_HELPER_VERSION,
};
const DIAG = {
  health: { status: "ok" },
  ready: { status: "not_ready", reason: "execution_unavailable" },
  capabilities: {
    backends: [],
    guest_abis: [],
    images: [],
    features: { execution: false, network_modes: [], snapshots: false, forks: false, sse: false },
    ceilings: {},
  },
  http: { health: 200, ready: 503, capabilities: 200 },
};

const FAKE_IO = `
const stdinDecoder = {
  buf: new Uint8Array(0),
  reader: Bun.stdin.stream().getReader(),
  concat(a, b) { const o = new Uint8Array(a.byteLength + b.byteLength); o.set(a, 0); o.set(b, a.byteLength); return o; },
  async readN(n) {
    while (this.buf.byteLength < n) {
      const { done, value } = await this.reader.read();
      if (done) throw new Error("eof");
      this.buf = this.concat(this.buf, value);
    }
    const out = this.buf.slice(0, n);
    this.buf = this.buf.slice(n);
    return out;
  },
  async readFrame() {
    const header = await this.readN(4);
    const len = new DataView(header.buffer, header.byteOffset, 4).getUint32(0, false);
    return this.readN(len);
  }
};
function frame(bytes) {
  const out = new Uint8Array(4 + bytes.length);
  new DataView(out.buffer).setUint32(0, bytes.length, false);
  out.set(bytes, 4);
  return out;
}
async function reply(result) {
  const payload = await stdinDecoder.readFrame();
  const req = JSON.parse(Buffer.from(payload).toString("utf8"));
  const body = JSON.stringify({ v: "${SDK_HELPER_PROTOCOL}", id: req.id, ok: true, result });
  await Bun.write(Bun.stdout, frame(Buffer.from(body)));
  return req;
}
`;

async function writeFake(name: string, body: string): Promise<string> {
  const file = join(scratch, name);
  await Bun.write(file, body);
  return file;
}

function transportFor(script: string, extra?: Partial<ConstructorParameters<typeof OwnedHelperTransport>[0]>) {
  return new OwnedHelperTransport({
    helperPath: bunPath,
    helperArgs: [script],
    cwd: scratch,
    startupTimeoutMs: extra?.startupTimeoutMs ?? 2000,
    requestTimeoutMs: extra?.requestTimeoutMs ?? 2000,
    shutdownTimeoutMs: extra?.shutdownTimeoutMs ?? 2000,
    ...(extra?.maxStderrBytes !== undefined ? { maxStderrBytes: extra.maxStderrBytes } : {}),
    ...(extra?.maxStdoutBytes !== undefined ? { maxStdoutBytes: extra.maxStdoutBytes } : {}),
    ...(extra?.maxFrameBytes !== undefined ? { maxFrameBytes: extra.maxFrameBytes } : {}),
  });
}

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

function retainPid(pid: number | null | undefined): void {
  if (!pid || pid <= 0) return;
  if (processAlive(pid)) live.add(pid);
  else live.delete(pid);
}

async function closeTracked(transport: OwnedHelperTransport): Promise<void> {
  const pid = transport.lastPid;
  if (pid) live.add(pid);
  try {
    await boundedRace(transport.close(), 8000, `close_timeout pid=${pid ?? 0}`);
  } catch {
    // retain unresolved pid/dir for afterAll
  } finally {
    retainPid(transport.lastPid ?? pid);
  }
}

async function expectTypedFailure(
  work: () => Promise<unknown>,
  transport: OwnedHelperTransport,
  ctor: new (...args: never[]) => Error,
  code?: string,
): Promise<unknown> {
  let err: unknown;
  try {
    await work();
  } catch (e) {
    err = e;
  }
  const pid = transport.lastPid;
  if (pid) live.add(pid);
  try {
    expect(err).toBeInstanceOf(ctor);
    if (code && err instanceof LocalRuntimeError) expect(err.code).toBe(code);
    if (pid) {
      expect(processAlive(pid)).toBe(false);
      live.delete(pid);
    }
    return err;
  } finally {
    await closeTracked(transport);
  }
}

describe("adversarial fake helper streams", () => {
  test("constructor rejects non-integer and non-finite resource bounds", () => {
    const base = { helperPath: bunPath };
    expect(() => new OwnedHelperTransport({ ...base, maxFrameBytes: Number.NaN })).toThrow(HelperStartupError);
    expect(() => new OwnedHelperTransport({ ...base, maxStdoutBytes: Number.POSITIVE_INFINITY })).toThrow(HelperStartupError);
    expect(() => new OwnedHelperTransport({ ...base, maxStderrBytes: Number.NaN })).toThrow(HelperStartupError);
    expect(() => new OwnedHelperTransport({ ...base, maxFrameBytes: 1.5 })).toThrow(HelperStartupError);
    expect(() => new OwnedHelperTransport({ ...base, startupTimeoutMs: 0 })).toThrow(HelperStartupError);
  });

  test("partial frame then EOF fails closed with eof and reaps", async () => {
    const script = await writeFake(
      "partial.ts",
      `${FAKE_IO}
const { closeSync } = await import("node:fs");
await stdinDecoder.readFrame();
const header = Buffer.alloc(4); header.writeUInt32BE(20, 0); await Bun.write(Bun.stdout, header); await Bun.write(Bun.stdout, Buffer.from("abc"));
closeSync(1);
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError, "eof");
  });

  test("valid partial frames coalesce into hello", async () => {
    const script = await writeFake(
      "partial-ok.ts",
      `${FAKE_IO}
const payload = await stdinDecoder.readFrame();
const req = JSON.parse(Buffer.from(payload).toString("utf8"));
const body = Buffer.from(JSON.stringify({ v: "${SDK_HELPER_PROTOCOL}", id: req.id, ok: true, result: ${JSON.stringify(HELLO)} }));
const framed = frame(body);
await Bun.write(Bun.stdout, framed.subarray(0, 3));
await Bun.sleep(40);
await Bun.write(Bun.stdout, framed.subarray(3));
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    try {
      const hello = await transport.open();
      if (transport.lastPid) live.add(transport.lastPid);
      expect(hello.protocol).toBe(SDK_HELPER_PROTOCOL);
    } finally {
      await closeTracked(transport);
    }
    expect(processAlive(transport.lastPid!)).toBe(false);
  });

  test("oversize length prefix fails closed", async () => {
    const script = await writeFake(
      "oversize.ts",
      `const header = Buffer.alloc(4); header.writeUInt32BE(70000, 0); await Bun.write(Bun.stdout, header); await new Promise((r) => setTimeout(r, 5000));`,
    );
    const transport = transportFor(script);
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError, "oversize");
  });

  test("malformed json fails closed after the fixture is delivered", async () => {
    const script = await writeFake(
      "malformed.ts",
      `${FAKE_IO}
await stdinDecoder.readFrame();
await Bun.write(Bun.stdout, frame(Buffer.from("{not-json")));
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError, "malformed");
  });

  test("version mismatch fails closed", async () => {
    const script = await writeFake(
      "version.ts",
      `${FAKE_IO}
const payload = await stdinDecoder.readFrame();
const req = JSON.parse(Buffer.from(payload).toString("utf8"));
const body = JSON.stringify({ v: "sdk-helper/0", id: req.id, ok: true, result: { protocol: "sdk-helper/0" } });
await Bun.write(Bun.stdout, frame(Buffer.from(body)));
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    await expectTypedFailure(() => transport.open(), transport, HelperVersionError, "version_mismatch");
  });

  test("wrong id fails closed", async () => {
    const script = await writeFake(
      "wrong-id.ts",
      `${FAKE_IO}
await stdinDecoder.readFrame();
const body = JSON.stringify({ v: "${SDK_HELPER_PROTOCOL}", id: "req_other", ok: true, result: ${JSON.stringify(HELLO)} });
await Bun.write(Bun.stdout, frame(Buffer.from(body)));
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError, "wrong_id");
  });

  test("duplicate completion of the in-flight id fails closed", async () => {
    const script = await writeFake(
      "dup-complete.ts",
      `${FAKE_IO}
const payload = await stdinDecoder.readFrame();
const req = JSON.parse(Buffer.from(payload).toString("utf8"));
const body = JSON.stringify({ v: "${SDK_HELPER_PROTOCOL}", id: req.id, ok: true, result: ${JSON.stringify(HELLO)} });
const framed = frame(Buffer.from(body));
await Bun.write(Bun.stdout, framed);
await Bun.write(Bun.stdout, framed);
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    let openErr: unknown;
    try {
      try {
        await transport.open();
      } catch (e) {
        openErr = e;
      }
      if (transport.lastPid) live.add(transport.lastPid);
      if (openErr) {
        expect(openErr).toBeInstanceOf(HelperProtocolError);
        expect((openErr as HelperProtocolError).code).toBe("unexpected");
      } else {
        const waitUntil = Date.now() + 2000;
        while (transport.state === "open" && Date.now() < waitUntil) {
          await Bun.sleep(10);
        }
        let later: unknown;
        try {
          await transport.request("diagnostics", undefined);
        } catch (e) {
          later = e;
        }
        expect(later).toBeInstanceOf(HelperProtocolError);
        expect((later as HelperProtocolError).code).toBe("unexpected");
      }
    } finally {
      await closeTracked(transport);
    }
    expect(processAlive(transport.lastPid!)).toBe(false);
  });

  test("coalesced header+body is decoded by a persistent buffer", () => {
    const decoder = new (class extends Object {
      buf = new Uint8Array(0);
      concat(a: Uint8Array, b: Uint8Array) {
        const o = new Uint8Array(a.byteLength + b.byteLength);
        o.set(a, 0);
        o.set(b, a.byteLength);
        return o;
      }
      push(chunk: Uint8Array) {
        this.buf = this.concat(this.buf, chunk);
      }
      readN(n: number): Uint8Array {
        if (this.buf.byteLength < n) throw new Error("eof");
        const out = this.buf.slice(0, n);
        this.buf = this.buf.slice(n);
        return out;
      }
    })();
    decoder.push(Uint8Array.from([0, 0, 0, 3, 65, 66, 67]));
    const header = decoder.readN(4);
    const body = decoder.readN(3);
    expect(Array.from(header)).toEqual([0, 0, 0, 3]);
    expect(Array.from(body)).toEqual([65, 66, 67]);
  });

  test("ambiguous ok+error response is rejected", () => {
    const bytes = new TextEncoder().encode(
      JSON.stringify({ v: SDK_HELPER_PROTOCOL, id: "req_a", ok: true, result: {}, error: { code: "bad", message: "bad" } }),
    );
    expect(() => parseHelperResponse(bytes)).toThrow(HelperProtocolError);
  });

  test("helper death during startup fails closed", async () => {
    const script = await writeFake("die.ts", `process.exit(7);`);
    const transport = transportFor(script);
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError);
  });

  test("stderr flood fails closed and reaps", async () => {
    const script = await writeFake(
      "stderr-flood.ts",
      `const chunk = Buffer.alloc(4096, 88);
for (let i = 0; i < 64; i++) await Bun.write(Bun.stderr, chunk);
await new Promise((r) => setTimeout(r, 10000));
`,
    );
    const transport = transportFor(script, { maxStderrBytes: 8192, startupTimeoutMs: 3000 });
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError, "stderr_flood");
  });

  test("stdout flood fails closed and reaps", async () => {
    const script = await writeFake(
      "stdout-flood.ts",
      `const header = Buffer.alloc(4); header.writeUInt32BE(1, 0); await Bun.write(Bun.stdout, header); await new Promise((r) => setTimeout(r, 10000));`,
    );
    const transport = transportFor(script, { maxStdoutBytes: 3, startupTimeoutMs: 3000 });
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError, "flood");
  });

  test("request timeout on silent helper", async () => {
    const script = await writeFake("silent.ts", `await new Promise((r) => setTimeout(r, 20000));`);
    const transport = transportFor(script, { startupTimeoutMs: 200 });
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError, "deadline");
  });

  test("abort during request fails closed and reaps", async () => {
    const script = await writeFake(
      "slow-hello.ts",
      `${FAKE_IO}
await stdinDecoder.readFrame();
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const controller = new AbortController();
    const transport = transportFor(script, { startupTimeoutMs: 5000 });
    setTimeout(() => controller.abort(), 50);
    await expectTypedFailure(() => transport.open(controller.signal), transport, HelperClosedError, "aborted");
  });

  test("abort before startup does not spawn", async () => {
    const script = await writeFake("never.ts", `await new Promise((r) => setTimeout(r, 20000));`);
    const controller = new AbortController();
    controller.abort();
    const transport = transportFor(script);
    await expectTypedFailure(() => transport.open(controller.signal), transport, HelperClosedError, "aborted");
    expect(transport.lastPid).toBeNull();
  });

  test("invalid utf-8 payload fails closed", async () => {
    const script = await writeFake(
      "bad-utf8.ts",
      `${FAKE_IO}
await stdinDecoder.readFrame();
await Bun.write(Bun.stdout, frame(Uint8Array.from([0xff, 0xfe, 0xfd, 0x80])));
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError, "malformed");
  });

  test("one in-flight plus busy reject after successful open", async () => {
    const script = await writeFake(
      "hold.ts",
      `${FAKE_IO}
await reply(${JSON.stringify(HELLO)});
await stdinDecoder.readFrame();
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script, { startupTimeoutMs: 3000, requestTimeoutMs: 3000 });
    try {
      await transport.open();
      if (transport.lastPid) live.add(transport.lastPid);
      const blockedOutcome = transport.request("diagnostics", undefined).then(
        (value): { fulfilled: true; value: unknown } | { fulfilled: false; error: unknown } => ({
          fulfilled: true,
          value,
        }),
        (error: unknown) => ({ fulfilled: false, error }),
      );
      let busy: unknown;
      try {
        await transport.request("diagnostics", undefined);
      } catch (e) {
        busy = e;
      }
      expect(busy).toBeInstanceOf(HelperBusyError);
      await closeTracked(transport);
      const outcome = await boundedRace(blockedOutcome, 5000, "blocked_request_drain");
      if (outcome.fulfilled) {
        throw new Error("blocked request unexpectedly fulfilled");
      }
      expect(outcome.error).toBeInstanceOf(HelperClosedError);
      expect((outcome.error as HelperClosedError).code).toBe("closing");
    } finally {
      await closeTracked(transport);
    }
    expect(processAlive(transport.lastPid!)).toBe(false);
  });

  test("encodeFrame rejects oversize", () => {
    expect(() => encodeFrame(new Uint8Array(70000))).toThrow(HelperProtocolError);
  });

  test("hello then invalid diagnostics reaps the owned pid before open rejects", async () => {
    const script = await writeFake(
      "hello-bad-diag.ts",
      `${FAKE_IO}
await reply(${JSON.stringify(HELLO)});
await reply({ bad: true });
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    const err = await expectTypedFailure(
      () => LocalSandbox.open({ transport }),
      transport,
      LocalRuntimeError,
      "unexpected_diagnostics",
    );
    expect(err).toBeInstanceOf(LocalRuntimeError);
    expect(transport.lastPid).toBeGreaterThan(0);
    expect(processAlive(transport.lastPid!)).toBe(false);
  });

  test("close while in-flight reaps", async () => {
    const script = await writeFake(
      "close-inflight.ts",
      `${FAKE_IO}
await reply(${JSON.stringify(HELLO)});
await stdinDecoder.readFrame();
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    try {
      await transport.open();
      if (transport.lastPid) live.add(transport.lastPid);
      const pendingOutcome = transport.request("diagnostics", undefined).then(
        (value): { fulfilled: true; value: unknown } | { fulfilled: false; error: unknown } => ({
          fulfilled: true,
          value,
        }),
        (error: unknown) => ({ fulfilled: false, error }),
      );
      await closeTracked(transport);
      const outcome = await boundedRace(pendingOutcome, 5000, "inflight_drain");
      if (outcome.fulfilled) {
        throw new Error("in-flight request unexpectedly fulfilled");
      }
      expect(outcome.error).toBeInstanceOf(HelperClosedError);
      expect((outcome.error as HelperClosedError).code).toBe("closing");
    } finally {
      await closeTracked(transport);
    }
    expect(processAlive(transport.lastPid!)).toBe(false);
  });

  test("cleanup reaps fake helper", async () => {
    const script = await writeFake(
      "ok-hello.ts",
      `${FAKE_IO}
await reply(${JSON.stringify(HELLO)});
await reply(${JSON.stringify(DIAG)});
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const runtime = await LocalSandbox.open({
      helperPath: bunPath,
      helperArgs: [script],
      cwd: scratch,
      startupTimeoutMs: 2000,
      requestTimeoutMs: 2000,
      shutdownTimeoutMs: 2000,
    });
    const pid = runtime.helperPid;
    if (pid) live.add(pid);
    try {
      expect(pid).toBeGreaterThan(0);
      await runtime.close();
      await runtime.close();
      expect(runtime.helperPid).toBeNull();
      expect(processAlive(pid!)).toBe(false);
    } finally {
      try {
        await runtime.close();
      } catch {
        // retain unresolved pid
      }
      retainPid(pid);
    }
  });

  test("blocked write is raced against the request deadline", async () => {
    const script = await writeFake("never-read.ts", `await new Promise((r) => setTimeout(r, 20000));`);
    const transport = transportFor(script, { startupTimeoutMs: 150, shutdownTimeoutMs: 1000 });
    const started = Date.now();
    await expectTypedFailure(() => transport.open(), transport, HelperProtocolError, "deadline");
    expect(Date.now() - started).toBeLessThan(2000);
  });

  test("parseHelperHello requires exact zig-sandbox-helper@0.1.0-ts0", () => {
    expect(parseHelperHello(HELLO)).toEqual(HELLO);
    expect(() => parseHelperHello({ ...HELLO, helper: "other-helper" })).toThrow(HelperVersionError);
    expect(() => parseHelperHello({ ...HELLO, helper_version: "9.9" })).toThrow(HelperVersionError);
  });

  test("fake helper identity mismatch fails closed and reaps", async () => {
    const script = await writeFake(
      "bad-identity.ts",
      `${FAKE_IO}
await reply(${JSON.stringify({ ...HELLO, helper: "other-helper", helper_version: "9.9" })});
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    await expectTypedFailure(() => transport.open(), transport, HelperVersionError, "version_mismatch");
  });

  test("successful request does not poison state; graceful close sends shutdown", async () => {
    const marker = join(scratch, "graceful-shutdown-seen.txt");
    const script = await writeFake(
      "graceful-shutdown.ts",
      `${FAKE_IO}
await reply(${JSON.stringify(HELLO)});
while (true) {
  const payload = await stdinDecoder.readFrame();
  const req = JSON.parse(Buffer.from(payload).toString("utf8"));
  if (req.method === "shutdown") {
    await Bun.write(${JSON.stringify(marker)}, "shutdown");
    const body = JSON.stringify({ v: "${SDK_HELPER_PROTOCOL}", id: req.id, ok: true, result: {} });
    await Bun.write(Bun.stdout, frame(Buffer.from(body)));
    break;
  }
  const body = JSON.stringify({ v: "${SDK_HELPER_PROTOCOL}", id: req.id, ok: true, result: ${JSON.stringify(DIAG)} });
  await Bun.write(Bun.stdout, frame(Buffer.from(body)));
}
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    try {
      await transport.open();
      if (transport.lastPid) live.add(transport.lastPid);
      await transport.request("diagnostics", undefined);
      expect(transport.state).toBe("open");
      await boundedRace(transport.close(), 8000, "graceful_close");
      expect(transport.state).toBe("closed");
      expect(await Bun.file(marker).text()).toBe("shutdown");
    } finally {
      await closeTracked(transport);
    }
    expect(processAlive(transport.lastPid!)).toBe(false);
  });

  test("actual helper failure after success still fail-closes", async () => {
    const script = await writeFake(
      "fail-after-success.ts",
      `${FAKE_IO}
await reply(${JSON.stringify(HELLO)});
await stdinDecoder.readFrame();
await Bun.write(Bun.stdout, frame(Buffer.from("{not-json")));
await new Promise((r) => setTimeout(r, 20000));
`,
    );
    const transport = transportFor(script);
    try {
      await transport.open();
      if (transport.lastPid) live.add(transport.lastPid);
      await expectTypedFailure(
        () => transport.request("diagnostics", undefined),
        transport,
        HelperProtocolError,
        "malformed",
      );
    } finally {
      await closeTracked(transport);
    }
    expect(processAlive(transport.lastPid!)).toBe(false);
  });
});

describe("stalled flush request races", () => {
  async function withStalledFlush(kind: "success" | "error" | "abort"): Promise<{
    settled: { outcome: string; code?: string; elapsed_ms: number } | null;
    atWatchdogUnhandled: Array<{ code: string | null }>;
    laterUnhandled: unknown[];
    killed: number;
    writerAborted: boolean;
    timeoutCleared: boolean;
  }> {
    let release!: () => void;
    const stalledFlush = new Promise<number>((r) => {
      release = () => r(0);
    });
    let killed = 0;
    let exitCode: number | null = null;
    let reportExit!: (code: number) => void;
    const exited = new Promise<number>((r) => {
      reportExit = r;
    });
    const t = new OwnedHelperTransport({
      helperPath: bunPath,
      requestTimeoutMs: 25,
      shutdownTimeoutMs: 25,
    });
    const anyt = t as unknown as {
      state: string;
      owned: unknown;
      writerAbort: AbortController | null;
      request: typeof t.request;
      dispatchFrame: (frame: Uint8Array) => void;
    };
    anyt.state = "open";
    anyt.owned = {
      pid: 987654321,
      stdin: {
        write(data: Uint8Array) {
          return data.byteLength;
        },
        flush() {
          return stalledFlush;
        },
        end() {
          return 0;
        },
      },
      exited,
      get exitCode() {
        return exitCode;
      },
      kill() {
        killed += 1;
        exitCode = 0;
        reportExit(0);
      },
    };
    const controller = new AbortController();
    const start = performance.now();
    let settled: { outcome: string; code?: string; elapsed_ms: number } | null = null;
    const localUnhandled: Array<{ code: string | null }> = [];
    const onUnhandled = (e: unknown) => {
      localUnhandled.push({ code: e instanceof LocalRuntimeError ? e.code : null });
    };
    process.on("unhandledRejection", onUnhandled);
    const unhandledStart = unhandled.length;
    try {
      const request = t.request("diagnostics", undefined, controller.signal).then(
        () => {
          settled = { outcome: "resolved", elapsed_ms: performance.now() - start };
        },
        (error: unknown) => {
          settled = {
            outcome: "rejected",
            code: error instanceof LocalRuntimeError ? error.code : undefined,
            elapsed_ms: performance.now() - start,
          };
        },
      );
      if (kind === "abort") controller.abort("review abort during flush");
      else {
        anyt.dispatchFrame(
          new TextEncoder().encode(
            JSON.stringify({
              v: SDK_HELPER_PROTOCOL,
              id: "req_1",
              ok: kind === "success",
              ...(kind === "success"
                ? { result: { review: true } }
                : { error: { code: "review_rejection", message: "review error reply" } }),
            }),
          ),
        );
      }
      await boundedRace(request, 80, `${kind}_flush_deadline`);
      const atWatchdogUnhandled = localUnhandled.slice();
      expect(settled).not.toBeNull();
      expect(settled?.elapsed_ms).toBeLessThan(80);
      if (kind === "success") {
        expect(settled?.outcome).toBe("rejected");
        expect(settled?.code).toBe("deadline");
      }
      if (kind === "abort") {
        expect(settled?.outcome).toBe("rejected");
        expect(settled?.code).toBe("aborted");
      }
      if (kind === "error") {
        expect(settled?.outcome).toBe("rejected");
        expect(settled?.code === "review_rejection" || settled?.code === "deadline").toBe(true);
      }
      const writerAborted = anyt.writerAbort === null || anyt.writerAbort.signal.aborted;
      release();
      await Bun.sleep(30);
      expect(settled?.outcome).toBe("rejected");
      if (kind === "success") expect(settled?.code).toBe("deadline");
      expect(unhandled.slice(unhandledStart)).toEqual([]);
      return {
        settled,
        atWatchdogUnhandled,
        laterUnhandled: unhandled.slice(unhandledStart),
        killed,
        writerAborted,
        timeoutCleared: true,
      };
    } finally {
      process.off("unhandledRejection", onUnhandled);
      release();
      try {
        await boundedRace(t.close(), 1000, "stalled_flush_close");
      } catch {
        // retain mock
      }
    }
  }

  test("successful reply during stalled flush cannot beat the whole-operation deadline", async () => {
    const result = await withStalledFlush("success");
    expect(result.settled?.code).toBe("deadline");
    expect(result.atWatchdogUnhandled).toEqual([]);
    expect(result.laterUnhandled).toEqual([]);
    expect(result.writerAborted).toBe(true);
  });

  test("error reply during stalled flush settles without unhandled rejection", async () => {
    const result = await withStalledFlush("error");
    expect(result.settled?.outcome).toBe("rejected");
    expect(result.atWatchdogUnhandled).toEqual([]);
    expect(result.laterUnhandled).toEqual([]);
    expect(result.writerAborted).toBe(true);
  });

  test("abort during stalled flush settles without unhandled rejection", async () => {
    const result = await withStalledFlush("abort");
    expect(result.settled?.code).toBe("aborted");
    expect(result.atWatchdogUnhandled).toEqual([]);
    expect(result.laterUnhandled).toEqual([]);
    expect(result.killed).toBeGreaterThan(0);
    expect(result.writerAborted).toBe(true);
  });
});
