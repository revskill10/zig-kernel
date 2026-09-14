import { describe, expect, test } from "bun:test";
import { HelperClosedError, LocalRuntimeError, SandboxUnavailableError } from "../src/errors.ts";
import { RemoteSandbox, type RemoteTransport } from "../src/remote.ts";
import {
  DIAGNOSTIC_EMPTY_CAPABILITIES,
  DIAGNOSTIC_EXECUTION_UNAVAILABLE,
  isCanonicalEnvelope,
  isDiagnosticEnvelope,
} from "../src/types.ts";

const HEALTH = '{"status":"ok"}\n';
const READY = '{"status":"not_ready","reason":"execution_unavailable"}\n';
const CAPS =
  '{"backends":[],"guest_abis":[],"images":[],"features":{"execution":false,"network_modes":[],"snapshots":false,"forks":false,"sse":false},"ceilings":{}}\n';
const CREATE =
  '{"error":{"code":"execution_unavailable","message":"sandbox execution is not implemented in this bootstrap"}}\n';

function bootstrapTransport(): RemoteTransport {
  return {
    async fetch(request) {
      if (request.method === "GET" && request.path === "/healthz") return { status: 200, body: HEALTH };
      if (request.method === "GET" && request.path === "/readyz") return { status: 503, body: READY };
      if (request.method === "GET" && request.path === "/v1/capabilities") return { status: 200, body: CAPS };
      if (request.method === "POST" && request.path === "/v1/sandboxes") return { status: 501, body: CREATE };
      return { status: 404, body: '{"error":{"code":"not_found","message":"route not found"}}\n' };
    },
  };
}

describe("remote contract parity", () => {
  test("health, ready 503, capabilities execution false match bootstrap documents", async () => {
    const remote = new RemoteSandbox({ transport: bootstrapTransport() });
    expect(await remote.health()).toEqual({ status: "ok" });
    const ready = await remote.ready();
    expect(ready.status).toBe(503);
    expect(ready.document.reason).toBe("execution_unavailable");
    const caps = await remote.capabilities();
    expect(caps).toEqual(DIAGNOSTIC_EMPTY_CAPABILITIES);
    expect(caps.features.execution).toBe(false);
    expect(Object.isFrozen(caps.features)).toBe(true);
    expect(() => {
      caps.features.execution = true;
    }).toThrow();
    expect((await remote.capabilities()).features.execution).toBe(false);
  });

  test("create returns typed unavailable with diagnostic provenance and no invented request id", async () => {
    const remote = new RemoteSandbox({ transport: bootstrapTransport() });
    let err: unknown;
    try {
      await remote.create({
        profile: "linux-vm/x64",
        image: { id: "example", digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" },
      });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(SandboxUnavailableError);
    const unavailable = err as SandboxUnavailableError;
    expect(unavailable.provenance).toBe("remote");
    expect(unavailable.httpStatus).toBe(501);
    expect(unavailable.diagnostic).toEqual(DIAGNOSTIC_EXECUTION_UNAVAILABLE);
    expect(isDiagnosticEnvelope(CREATE)).toBe(true);
    expect(isCanonicalEnvelope(CREATE)).toBe(false);
    expect(JSON.stringify(unavailable.diagnostic).includes("request_id")).toBe(false);
  });

  test("exec is typed unavailable and remote never spawns a helper", async () => {
    const spawned: string[] = [];
    const transport: RemoteTransport = {
      async fetch(request) {
        spawned.push(`${request.method} ${request.path}`);
        return bootstrapTransport().fetch(request);
      },
    };
    const remote = new RemoteSandbox({ transport });
    let err: unknown;
    try {
      await remote.exec();
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(SandboxUnavailableError);
    expect(spawned).toEqual([]);
    expect(typeof Bun.spawn).toBe("function");
  });

  test("root package entry does not import local helper transport", async () => {
    const src = await Bun.file(new URL("../src/index.ts", import.meta.url)).text();
    expect(src.includes("./local")).toBe(false);
    expect(src.includes("transports/helper")).toBe(false);
    expect(src.includes("Bun.spawn")).toBe(false);
    const remoteSrc = await Bun.file(new URL("../src/remote.ts", import.meta.url)).text();
    expect(remoteSrc.includes("Bun.spawn")).toBe(false);
    expect(remoteSrc.includes("./local")).toBe(false);
  });

  test("empty capabilities object is rejected", async () => {
    const remote = new RemoteSandbox({ transport: { async fetch() { return { status: 200, body: "{}" }; } } });
    let err: unknown;
    try {
      await remote.capabilities();
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(LocalRuntimeError);
    expect((err as LocalRuntimeError).code).toBe("malformed");
  });

  test("401 unauthorized is not mapped to execution_unavailable", async () => {
    const remote = new RemoteSandbox({
      transport: {
        async fetch() {
          return { status: 401, body: JSON.stringify({ error: { code: "unauthorized", message: "denied" } }) };
        },
      },
    });
    let err: unknown;
    try {
      await remote.create({ profile: "x", image: { id: "x", digest: "x" } });
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(LocalRuntimeError);
    expect(err).not.toBeInstanceOf(SandboxUnavailableError);
    expect((err as LocalRuntimeError).code).toBe("unauthorized");
    expect((err as LocalRuntimeError).httpStatus).toBe(401);
  });

  test("403, 409, and 500 protocol errors keep their codes", async () => {
    for (const [status, code] of [
      [403, "forbidden"],
      [409, "conflict"],
      [500, "internal"],
    ] as const) {
      const remote = new RemoteSandbox({
        transport: {
          async fetch() {
            return { status, body: JSON.stringify({ error: { code, message: code } }) };
          },
        },
      });
      let err: unknown;
      try {
        await remote.create({ profile: "x", image: { id: "x", digest: "x" } });
      } catch (e) {
        err = e;
      }
      expect(err).toBeInstanceOf(LocalRuntimeError);
      expect(err).not.toBeInstanceOf(SandboxUnavailableError);
      expect((err as LocalRuntimeError).code).toBe(code);
      expect((err as LocalRuntimeError).httpStatus).toBe(status);
    }
  });

  test("remote body is bounded before parse", async () => {
    const remote = new RemoteSandbox({
      transport: { async fetch() { return { status: 200, body: "x".repeat(80 * 1024) }; } },
      maxBodyBytes: 1024,
    });
    let err: unknown;
    try {
      await remote.health();
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(LocalRuntimeError);
    expect((err as LocalRuntimeError).code).toBe("payload_too_large");
  });

  test("utf8 body bound counts encoded bytes not UTF-16 code units", async () => {
    const body = JSON.stringify({ status: "ok", ignored: "😀".repeat(30) });
    expect(body.length).toBe(88);
    expect(new TextEncoder().encode(body).byteLength).toBe(148);
    const remote = new RemoteSandbox({
      maxBodyBytes: 100,
      transport: { async fetch() { return { status: 200, body }; } },
    });
    let err: unknown;
    try {
      await remote.health();
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(LocalRuntimeError);
    expect((err as LocalRuntimeError).code).toBe("payload_too_large");
  });

  test("outbound JSON is bounded before the transport is invoked", async () => {
    let called = 0;
    const remote = new RemoteSandbox({
      maxBodyBytes: 32,
      transport: {
        async fetch() {
          called += 1;
          return { status: 501, body: CREATE };
        },
      },
    });
    let err: unknown;
    try {
      await remote.create({
        profile: "linux-vm/x64",
        image: { id: "example", digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" },
      });
    } catch (e) {
      err = e;
    }
    expect(called).toBe(0);
    expect(err).toBeInstanceOf(LocalRuntimeError);
    expect((err as LocalRuntimeError).code).toBe("payload_too_large");
  });

  test("ignored transport signal still settles by client deadline and observes late rejection", async () => {
    const seen: unknown[] = [];
    const onUnhandled = (e: unknown) => {
      seen.push(e);
    };
    process.on("unhandledRejection", onUnhandled);
    let rejectFetch!: (reason: unknown) => void;
    const hung = new Promise<{ status: number; body: string }>((_, reject) => {
      rejectFetch = reject;
    });
    const remote = new RemoteSandbox({
      requestTimeoutMs: 20,
      transport: {
        async fetch() {
          return hung;
        },
      },
    });
    const started = Date.now();
    let err: unknown;
    try {
      await remote.health();
    } catch (e) {
      err = e;
    }
    try {
      expect(err).toBeInstanceOf(LocalRuntimeError);
      expect((err as LocalRuntimeError).code).toBe("deadline");
      expect(Date.now() - started).toBeLessThan(80);
      rejectFetch(new Error("late fetch reject"));
      await Bun.sleep(20);
      expect(seen).toEqual([]);
    } finally {
      process.off("unhandledRejection", onUnhandled);
      await remote.close();
    }
  });

  test("pre-aborted request does not call transport", async () => {
    let called = 0;
    const remote = new RemoteSandbox({
      transport: {
        async fetch() {
          called += 1;
          return { status: 200, body: HEALTH };
        },
      },
    });
    const controller = new AbortController();
    controller.abort("already aborted");
    let err: unknown;
    try {
      await remote.health(controller.signal);
    } catch (e) {
      err = e;
    }
    expect(called).toBe(0);
    expect(err).toBeInstanceOf(HelperClosedError);
    expect((err as HelperClosedError).code).toBe("aborted");
  });

  test("close aborts and settles a pending call", async () => {
    const seen: unknown[] = [];
    const onUnhandled = (e: unknown) => {
      seen.push(e);
    };
    process.on("unhandledRejection", onUnhandled);
    let rejectFetch!: (reason: unknown) => void;
    const hung = new Promise<{ status: number; body: string }>((_, reject) => {
      rejectFetch = reject;
    });
    const remote = new RemoteSandbox({
      requestTimeoutMs: 5000,
      transport: {
        async fetch() {
          return hung;
        },
      },
    });
    const pending = remote.health();
    await remote.close();
    let err: unknown;
    try {
      await pending;
    } catch (e) {
      err = e;
    }
    try {
      expect(err).toBeInstanceOf(HelperClosedError);
      expect((err as HelperClosedError).code).toBe("closed");
      rejectFetch(new Error("late fetch after close"));
      await Bun.sleep(20);
      expect(seen).toEqual([]);
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });

  test("synchronous transport throw still clears deadline and listeners", async () => {
    const originalSet = globalThis.setTimeout;
    const originalClear = globalThis.clearTimeout;
    const active = new Set<ReturnType<typeof setTimeout>>();
    globalThis.setTimeout = ((fn: TimerHandler, ms?: number, ...args: unknown[]) => {
      const handle = originalSet(fn as (...a: unknown[]) => void, ms, ...args);
      active.add(handle);
      return handle;
    }) as typeof setTimeout;
    globalThis.clearTimeout = ((handle?: ReturnType<typeof setTimeout>) => {
      if (handle !== undefined) active.delete(handle);
      originalClear(handle);
    }) as typeof clearTimeout;
    const boom = new Error("synchronous transport failure");
    const seen: unknown[] = [];
    const onUnhandled = (e: unknown) => {
      seen.push(e);
    };
    process.on("unhandledRejection", onUnhandled);
    const user = new AbortController();
    const remote = new RemoteSandbox({
      requestTimeoutMs: 5000,
      transport: {
        fetch() {
          throw boom;
        },
      },
    });
    let err: unknown;
    try {
      await remote.health(user.signal);
    } catch (e) {
      err = e;
    }
    try {
      expect(err).toBe(boom);
      await remote.close();
      user.abort("after-close");
      await Bun.sleep(20);
      expect(active.size).toBe(0);
      expect(seen).toEqual([]);
    } finally {
      process.off("unhandledRejection", onUnhandled);
      for (const handle of active) originalClear(handle);
      active.clear();
      globalThis.setTimeout = originalSet;
      globalThis.clearTimeout = originalClear;
      await remote.close();
    }
  });
});
