import { dirname, isAbsolute, normalize } from "node:path";
import {
  HelperBusyError,
  HelperClosedError,
  HelperProtocolError,
  HelperStartupError,
  HelperVersionError,
  retainCleanupFailure,
} from "../errors.js";
import {
  DEFAULT_REQUEST_TIMEOUT_MS,
  DEFAULT_SHUTDOWN_TIMEOUT_MS,
  DEFAULT_STARTUP_TIMEOUT_MS,
  HELPER_ID_REPLAY_WINDOW,
  MAX_JSON_BYTES,
  MAX_REQUEST_SEQUENCE,
  MAX_STDERR_BYTES,
  MAX_STDOUT_BYTES,
  MAX_TIMEOUT_MS,
  SDK_HELPER_PROTOCOL,
  isOpaqueId,
  isRecord,
  parseHelperHello,
  type HelperHello,
  type HelperMethod,
  type HelperResponse,
  type LocalRuntimeState,
} from "../types.js";

export interface LocalEngineTransport {
  readonly state: LocalRuntimeState;
  readonly pid: number | null;
  readonly lastPid: number | null;
  open(signal?: AbortSignal): Promise<HelperHello>;
  request(method: HelperMethod, params: unknown, signal?: AbortSignal): Promise<unknown>;
  close(): Promise<void>;
}

export interface OwnedHelperOpenOptions {
  helperPath: string;
  helperArgs?: readonly string[];
  cwd?: string;
  helperEnv?: Record<string, string>;
  signal?: AbortSignal;
  startupTimeoutMs?: number;
  requestTimeoutMs?: number;
  shutdownTimeoutMs?: number;
  maxFrameBytes?: number;
  maxStdoutBytes?: number;
  maxStderrBytes?: number;
}

interface ByteSink {
  write(chunk: Uint8Array): number | Promise<number>;
  flush(): number | Promise<number>;
  end?(error?: Error): number | Promise<number>;
}

interface OwnedProcess {
  readonly pid: number;
  readonly stdin: ByteSink;
  readonly stdout: ReadableStream<Uint8Array>;
  readonly stderr: ReadableStream<Uint8Array>;
  readonly exited: Promise<number>;
  readonly exitCode: number | null;
  kill(): void;
}

const BLOCKED_ENV =
  /^(DOCKER_HOST|DOCKER_|SSH_|AWS_|GOOGLE_|AZURE_|KUBE|CLOUD|OCI_|GIT_|NPM_TOKEN|NODE_AUTH|BUN_AUTH|HOME|USERPROFILE|APPDATA|HOMEDRIVE|HOMEPATH|XDG_|REQUESTS_CA_BUNDLE|SSL_CERT|COMPOSER_|NETRC)/i;

function boundTimeout(value: number | undefined, fallback: number, label: string): number {
  const n = value ?? fallback;
  if (!Number.isInteger(n) || n <= 0 || n > MAX_TIMEOUT_MS) {
    throw new HelperStartupError("invalid_timeout", `${label} must be a finite positive integer <= ${MAX_TIMEOUT_MS}ms`);
  }
  return n;
}

function boundPositiveInt(value: number | undefined, fallback: number, max: number, label: string): number {
  const n = value ?? fallback;
  if (!Number.isInteger(n) || n <= 0 || n > max) {
    throw new HelperStartupError("invalid_bound", `${label} must be a finite positive integer <= ${max}`);
  }
  return n;
}

function isBlockedEnv(name: string): boolean {
  return BLOCKED_ENV.test(name) || name.includes("~") || name.toLowerCase().includes("secret");
}

export function helperEnvironment(extra?: Record<string, string>): Record<string, string> {
  const env: Record<string, string> = {};
  if (process.platform === "win32") {
    for (const key of ["SYSTEMROOT", "WINDIR"] as const) {
      const value = process.env[key];
      if (value) env[key] = value;
    }
  }
  if (extra) {
    for (const [key, value] of Object.entries(extra)) {
      if (isBlockedEnv(key)) {
        throw new HelperStartupError("blocked_env", `refusing to inherit or set ${key}`);
      }
      env[key] = value;
    }
  }
  return env;
}

export function assertTrustedHelperPath(helperPath: string): string {
  if (typeof helperPath !== "string" || helperPath.length === 0) {
    throw new HelperStartupError("invalid_helper_path", "explicit trusted helperPath is required");
  }
  if (helperPath.includes("\0") || /[\n\r]/.test(helperPath)) {
    throw new HelperStartupError("invalid_helper_path", "helperPath contains forbidden characters");
  }
  if (helperPath.startsWith("~") || helperPath.includes("%")) {
    throw new HelperStartupError("invalid_helper_path", "helperPath does not expand ~ or host variables");
  }
  if (!isAbsolute(helperPath)) {
    throw new HelperStartupError(
      "invalid_helper_path",
      "helperPath must be an explicit trusted absolute path; PATH search and shell expansion are not used",
    );
  }
  return normalize(helperPath);
}

export function encodeFrame(payload: Uint8Array, maxFrame = MAX_JSON_BYTES): Uint8Array {
  if (payload.byteLength === 0 || payload.byteLength > maxFrame) {
    throw new HelperProtocolError("payload_too_large", `frame payload ${payload.byteLength} is outside 1..${maxFrame}`);
  }
  const out = new Uint8Array(4 + payload.byteLength);
  new DataView(out.buffer).setUint32(0, payload.byteLength, false);
  out.set(payload, 4);
  return out;
}

export function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.byteLength + b.byteLength);
  for (let i = 0; i < a.byteLength; i += 1) out[i] = a[i] ?? 0;
  for (let i = 0; i < b.byteLength; i += 1) out[a.byteLength + i] = b[i] ?? 0;
  return out;
}

export class FrameDecoder {
  private buffer: Uint8Array = new Uint8Array(0);
  private stdoutBytes = 0;

  constructor(
    private readonly maxStdout: number,
    private readonly maxFrame: number,
  ) {}

  push(chunk: Uint8Array): Uint8Array[] {
    this.stdoutBytes += chunk.byteLength;
    if (this.stdoutBytes > this.maxStdout) {
      throw new HelperProtocolError("flood", "helper stdout exceeded bound");
    }
    this.buffer = concatBytes(this.buffer, chunk);
    const frames: Uint8Array[] = [];
    while (this.buffer.byteLength >= 4) {
      const len = new DataView(this.buffer.buffer, this.buffer.byteOffset, 4).getUint32(0, false);
      if (len === 0 || len > this.maxFrame) {
        throw new HelperProtocolError("oversize", `invalid helper frame length ${len}`);
      }
      if (this.buffer.byteLength < 4 + len) break;
      frames.push(this.buffer.slice(4, 4 + len));
      this.buffer = this.buffer.slice(4 + len);
    }
    return frames;
  }

  get pending(): number {
    return this.buffer.byteLength;
  }

  get sessionStdoutBytes(): number {
    return this.stdoutBytes;
  }
}

export function parseHelperResponse(bytes: Uint8Array): HelperResponse {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch (cause) {
    throw new HelperProtocolError("malformed", "helper frame is not valid utf-8", { cause });
  }
  let value: unknown;
  try {
    value = JSON.parse(text) as unknown;
  } catch (cause) {
    throw new HelperProtocolError("malformed", "helper frame is not valid json", { cause });
  }
  if (!isRecord(value)) {
    throw new HelperProtocolError("malformed", "helper response is not an object");
  }
  for (const key of Object.keys(value)) {
    if (key !== "v" && key !== "id" && key !== "ok" && key !== "result" && key !== "error") {
      throw new HelperProtocolError("unknown_field", `unexpected helper field ${key}`);
    }
  }
  if (typeof value.v !== "string" || typeof value.id !== "string" || typeof value.ok !== "boolean") {
    throw new HelperProtocolError("malformed", "helper response missing v, id, or ok");
  }
  if (!isOpaqueId(value.id)) {
    throw new HelperProtocolError("invalid_id", "helper response id is not a bounded opaque id");
  }
  if (value.v !== SDK_HELPER_PROTOCOL) {
    throw new HelperVersionError("version_mismatch", `helper protocol ${value.v} != ${SDK_HELPER_PROTOCOL}`);
  }
  if (value.ok) {
    if ("error" in value) {
      throw new HelperProtocolError("malformed", "ok helper response must not include error");
    }
    if (!("result" in value)) {
      throw new HelperProtocolError("missing_field", "ok helper response missing result");
    }
    return { ok: true, v: value.v, id: value.id, result: value.result };
  }
  if ("result" in value) {
    throw new HelperProtocolError("malformed", "error helper response must not include result");
  }
  if (!isRecord(value.error) || typeof value.error.code !== "string" || typeof value.error.message !== "string") {
    throw new HelperProtocolError("malformed", "helper error object is incomplete");
  }
  return {
    ok: false,
    v: value.v,
    id: value.id,
    error: { code: value.error.code, message: value.error.message },
  };
}

class Timeout {
  readonly promise: Promise<never>;
  private handle: ReturnType<typeof setTimeout> | undefined;
  private settled = false;

  constructor(ms: number, code: string, message: string) {
    this.promise = new Promise((_, reject) => {
      this.handle = setTimeout(() => {
        this.settled = true;
        reject(new HelperProtocolError(code, message));
      }, ms);
    });
    this.promise.catch(() => undefined);
  }

  clear(): void {
    if (this.handle !== undefined) {
      clearTimeout(this.handle);
      this.handle = undefined;
    }
  }

  get timedOut(): boolean {
    return this.settled;
  }
}

class OnceDeferred<T> {
  readonly promise: Promise<T>;
  private resolveFn!: (value: T) => void;
  private rejectFn!: (reason: unknown) => void;
  private settled = false;

  constructor() {
    this.promise = new Promise<T>((resolve, reject) => {
      this.resolveFn = resolve;
      this.rejectFn = reject;
    });
  }

  resolve(value: T): void {
    if (this.settled) return;
    this.settled = true;
    this.resolveFn(value);
  }

  reject(reason: unknown): void {
    if (this.settled) return;
    this.settled = true;
    this.rejectFn(reason);
  }
}

function yieldEventLoop(): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
}

async function writeAll(sink: ByteSink, data: Uint8Array, signal?: AbortSignal): Promise<void> {
  let offset = 0;
  while (offset < data.byteLength) {
    if (signal?.aborted) throw abortError(signal);
    const chunk = data.subarray(offset);
    const n = sink.write(chunk);
    const written = typeof n === "number" ? n : await n;
    if (signal?.aborted) throw abortError(signal);
    if (written > 0) {
      offset += written;
      continue;
    }
    const flushed = sink.flush();
    if (typeof flushed !== "number") await flushed;
    if (signal?.aborted) throw abortError(signal);
    await yieldEventLoop();
  }
  if (signal?.aborted) throw abortError(signal);
  const flushed = sink.flush();
  if (typeof flushed !== "number") await flushed;
  if (signal?.aborted) throw abortError(signal);
}

function abortError(signal?: AbortSignal): Error {
  const err = new HelperClosedError("aborted", "operation aborted");
  if (signal?.reason !== undefined) {
    err.cause = signal.reason;
  }
  return err;
}

function isByteSink(value: unknown): value is ByteSink {
  if (typeof value !== "object" || value === null) return false;
  const rec = value as { write?: unknown; flush?: unknown };
  return typeof rec.write === "function" && typeof rec.flush === "function";
}

function isReadableStream(value: unknown): value is ReadableStream<Uint8Array> {
  if (typeof value !== "object" || value === null) return false;
  const rec = value as { getReader?: unknown };
  return typeof rec.getReader === "function";
}

function spawnOwned(helperPath: string, args: readonly string[], cwd: string, env: Record<string, string>): OwnedProcess {
  const proc = Bun.spawn([helperPath, ...args], {
    cwd,
    env,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    windowsHide: true,
  });
  const stdin = proc.stdin;
  const stdout = proc.stdout;
  const stderr = proc.stderr;
  if (!isByteSink(stdin) || !isReadableStream(stdout) || !isReadableStream(stderr)) {
    try {
      proc.kill();
    } catch {
      // spawn produced no usable pipes; best-effort kill of the Bun handle
    }
    throw new HelperStartupError("spawn_failed", "helper stdio pipes were not connected");
  }
  return {
    pid: proc.pid,
    stdin,
    stdout,
    stderr,
    exited: proc.exited,
    get exitCode() {
      return proc.exitCode;
    },
    kill() {
      proc.kill();
    },
  };
}

type Pending = {
  id: string;
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
};

/**
 * First production-shaped local engine adapter: an SDK-owned Zig userspace
 * helper over private pipes. A future Bun-tested Node-API native adapter can
 * implement {@link LocalEngineTransport} separately; it is not shipped here.
 *
 * Request deadlines cover write+flush+reply from the start of the private-pipe
 * operation. `startupTimeoutMs` does not preempt a synchronous native
 * `Bun.spawn` call. Process termination is a separate bounded cleanup owned by
 * one supervisor; it is not folded into the request timer. stdout/stderr caps
 * are session-total.
 */
export class OwnedHelperTransport implements LocalEngineTransport {
  state: LocalRuntimeState = "closed";
  pid: number | null = null;
  lastPid: number | null = null;

  private readonly options: OwnedHelperOpenOptions;
  private readonly startupTimeoutMs: number;
  private readonly requestTimeoutMs: number;
  private readonly shutdownTimeoutMs: number;
  private readonly maxFrame: number;
  private readonly maxStdout: number;
  private readonly maxStderr: number;
  private owned: OwnedProcess | null = null;
  private stdoutReader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  private stderrReader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  private stdoutTask: Promise<void> | null = null;
  private stderrTask: Promise<void> | null = null;
  private pending: Pending | null = null;
  private inflight: Promise<unknown> | null = null;
  private seq = 0;
  private seenCompletions: string[] = [];
  private closePromise: Promise<void> | null = null;
  private failError: unknown = null;
  private cleanupError: unknown = null;
  private stderrBytes = 0;
  private decoder: FrameDecoder | null = null;
  private abortCleanup: (() => void) | null = null;
  private cleanupTask: Promise<void> | null = null;
  private exitConfirmed = false;
  private writerAbort: AbortController | null = null;
  private requestCancel: OnceDeferred<never> | null = null;

  constructor(options: OwnedHelperOpenOptions) {
    this.options = options;
    this.startupTimeoutMs = boundTimeout(options.startupTimeoutMs, DEFAULT_STARTUP_TIMEOUT_MS, "startupTimeoutMs");
    this.requestTimeoutMs = boundTimeout(options.requestTimeoutMs, DEFAULT_REQUEST_TIMEOUT_MS, "requestTimeoutMs");
    this.shutdownTimeoutMs = boundTimeout(options.shutdownTimeoutMs, DEFAULT_SHUTDOWN_TIMEOUT_MS, "shutdownTimeoutMs");
    this.maxFrame = boundPositiveInt(options.maxFrameBytes, MAX_JSON_BYTES, MAX_JSON_BYTES, "maxFrameBytes");
    this.maxStdout = boundPositiveInt(options.maxStdoutBytes, MAX_STDOUT_BYTES, MAX_STDOUT_BYTES, "maxStdoutBytes");
    this.maxStderr = boundPositiveInt(options.maxStderrBytes, MAX_STDERR_BYTES, MAX_STDERR_BYTES, "maxStderrBytes");
  }

  async open(signal?: AbortSignal): Promise<HelperHello> {
    if (this.owned) {
      throw new HelperStartupError("unresolved_ownership", "previous helper ownership is not fully discharged");
    }
    if (this.state !== "closed") {
      throw new HelperStartupError("already_open", `helper transport is ${this.state}`);
    }
    if (this.cleanupTask) {
      await this.cleanupTask.catch(() => undefined);
      if (this.owned) {
        throw new HelperStartupError("unresolved_ownership", "previous helper ownership is not fully discharged");
      }
    }
    this.resetSession();
    this.state = "starting";
    const helperPath = assertTrustedHelperPath(this.options.helperPath);
    const cwd = this.options.cwd ?? dirname(helperPath);
    if (!isAbsolute(cwd)) {
      this.state = "failed";
      throw new HelperStartupError("invalid_cwd", "cwd must be an explicit absolute path");
    }
    const combined = combineSignals(this.options.signal, signal);
    if (combined?.aborted) {
      this.state = "failed";
      throw abortError(combined);
    }

    let owned: OwnedProcess;
    try {
      owned = spawnOwned(helperPath, this.options.helperArgs ?? [], cwd, helperEnvironment(this.options.helperEnv));
    } catch (cause) {
      this.state = "failed";
      throw cause instanceof HelperStartupError
        ? cause
        : new HelperStartupError("spawn_failed", "failed to spawn trusted helper", { cause });
    }
    this.owned = owned;
    this.pid = owned.pid;
    this.lastPid = owned.pid;
    this.exitConfirmed = false;
    this.decoder = new FrameDecoder(this.maxStdout, this.maxFrame);
    this.stdoutReader = owned.stdout.getReader();
    this.stderrReader = owned.stderr.getReader();
    this.stdoutTask = this.readStdout();
    this.stderrTask = this.readStderr();
    this.observe(this.watchExit(owned));
    this.abortCleanup = listenOnce(combined, () => {
      this.signalFailure(abortError(combined), true);
    });

    try {
      const raw = await this.requestWithTimeout("hello", undefined, this.startupTimeoutMs, combined);
      let hello: HelperHello;
      try {
        hello = parseHelperHello(raw);
      } catch (cause) {
        if (cause instanceof HelperVersionError) throw cause;
        throw new HelperVersionError("version_mismatch", "helper hello identity is not the negotiated contract", { cause });
      }
      this.state = "open";
      return hello;
    } catch (err) {
      this.signalFailure(err, true);
      await this.joinCleanup(err);
      throw retainCleanupFailure(err, this.cleanupError);
    }
  }

  async request(method: HelperMethod, params: unknown, signal?: AbortSignal): Promise<unknown> {
    if (this.state !== "open") {
      throw this.failError instanceof Error
        ? this.failError
        : new HelperClosedError(this.state, `helper transport is ${this.state}`);
    }
    if (this.inflight) throw new HelperBusyError();
    const work = this.requestWithTimeout(method, params, this.requestTimeoutMs, signal);
    this.inflight = work;
    try {
      return await work;
    } finally {
      if (this.inflight === work) this.inflight = null;
    }
  }

  async close(): Promise<void> {
    if (this.state === "closed" && !this.owned) return;
    if (this.closePromise) return this.closePromise;
    this.closePromise = this.closeInner();
    try {
      await this.closePromise;
    } finally {
      this.closePromise = null;
    }
  }

  private async closeInner(): Promise<void> {
    const wasFailed = this.state === "failed" || this.failError !== null;
    if (this.state !== "failed") this.state = "closing";
    this.clearAbort();
    this.rejectPending(new HelperClosedError("closing", "helper transport is closing"));
    if (!wasFailed && this.owned && this.owned.exitCode === null) {
      try {
        await this.requestWithTimeout("shutdown", undefined, this.shutdownTimeoutMs);
      } catch {
        // graceful shutdown is best-effort; bounded reap still happens
      }
    }
    this.rejectPending(new HelperClosedError("closing", "helper transport is closing"));
    await this.joinCleanup(this.failError);
    if (this.owned && !this.exitConfirmed) {
      this.state = "failed";
      throw new HelperClosedError("cleanup_failed", "helper exit was not confirmed; retaining owned handle and pid", {
        cleanupFailure: this.cleanupError,
      });
    }
    this.pid = null;
    this.state = wasFailed || this.failError ? "failed" : "closed";
    if (!this.owned) this.state = "closed";
  }

  private async requestWithTimeout(
    method: HelperMethod,
    params: unknown,
    timeoutMs: number,
    signal?: AbortSignal,
  ): Promise<unknown> {
    if (this.pending) throw new HelperBusyError();
    if (signal?.aborted) throw abortError(signal);
    const owned = this.owned;
    if (!owned) {
      throw new HelperClosedError("closed", "helper stdin is unavailable");
    }
    const id = this.nextId();
    const body: Record<string, unknown> = { v: SDK_HELPER_PROTOCOL, id, method };
    if (params !== undefined) body.params = params;
    const payload = new TextEncoder().encode(JSON.stringify(body));
    const frame = encodeFrame(payload, this.maxFrame);
    const timeout = new Timeout(timeoutMs, "deadline", `${method} exceeded ${timeoutMs}ms`);
    const reply = new OnceDeferred<unknown>();
    this.observe(reply.promise);
    this.pending = {
      id,
      resolve: (value) => reply.resolve(value),
      reject: (reason) => reply.reject(reason),
    };
    const cancel = new OnceDeferred<never>();
    this.observe(cancel.promise);
    this.requestCancel = cancel;
    const writerAbort = new AbortController();
    this.writerAbort = writerAbort;
    const writeSignal = combineSignals(signal, writerAbort.signal);
    const stopAbort = listenOnce(signal, () => {
      this.signalFailure(abortError(signal), true);
    });
    const write = writeAll(owned.stdin, frame, writeSignal);
    this.observe(write);
    const io = Promise.all([write, reply.promise]).then(([, value]) => value);
    this.observe(io);
    try {
      return await Promise.race([io, timeout.promise, cancel.promise]);
    } catch (err) {
      reply.reject(err);
      if (this.pending?.id === id) this.pending = null;
      if (this.state === "open" || this.state === "starting") {
        this.signalFailure(err, true);
      } else {
        try {
          writerAbort.abort();
        } catch {
          // writer already cancelled
        }
        cancel.reject(err);
      }
      if (this.cleanupTask) {
        await this.joinCleanup(err);
      }
      throw retainCleanupFailure(err, this.cleanupError);
    } finally {
      stopAbort();
      timeout.clear();
      if (this.requestCancel === cancel) this.requestCancel = null;
      if (this.writerAbort === writerAbort) this.writerAbort = null;
      cancel.reject(new HelperClosedError("closed", "request finished"));
    }
  }

  private nextId(): string {
    if (this.seq >= MAX_REQUEST_SEQUENCE) {
      throw new HelperProtocolError("sequence_exhausted", "helper request sequence exhausted");
    }
    this.seq += 1;
    return `req_${this.seq}`;
  }

  private async readStdout(): Promise<void> {
    const reader = this.stdoutReader;
    const decoder = this.decoder;
    if (!reader || !decoder) return;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          if (this.pending || this.state === "open" || this.state === "starting") {
            this.signalFailure(new HelperProtocolError("eof", "helper stdout closed prematurely"), true);
          }
          return;
        }
        if (!value || value.byteLength === 0) continue;
        const frames = decoder.push(value);
        for (const frame of frames) this.dispatchFrame(frame);
      }
    } catch (err) {
      if (this.state === "open" || this.state === "starting") {
        this.signalFailure(err, true);
      }
    }
  }

  private async readStderr(): Promise<void> {
    const reader = this.stderrReader;
    if (!reader) return;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) return;
        if (!value) continue;
        this.stderrBytes += value.byteLength;
        if (this.stderrBytes > this.maxStderr) {
          this.signalFailure(new HelperProtocolError("stderr_flood", "helper stderr exceeded bound"), true);
          return;
        }
      }
    } catch {
      // reader cancellation during close is expected
    }
  }

  private async watchExit(owned: OwnedProcess): Promise<void> {
    try {
      const code = await owned.exited;
      this.exitConfirmed = true;
      if (this.state === "open" || this.state === "starting") {
        this.signalFailure(new HelperProtocolError("helper_exit", `helper exited ${code}`), false);
      }
    } catch (err) {
      if (this.state === "open" || this.state === "starting") {
        this.signalFailure(err, true);
      }
    }
  }

  private dispatchFrame(frame: Uint8Array): void {
    try {
      const response = parseHelperResponse(frame);
      if (!this.pending) {
        throw new HelperProtocolError("unexpected", "helper sent a frame with no in-flight request");
      }
      if (response.id !== this.pending.id) {
        throw new HelperProtocolError("wrong_id", `helper id ${response.id} != ${this.pending.id}`);
      }
      if (this.seenCompletions.includes(response.id)) {
        throw new HelperProtocolError("duplicate_id", "helper completed the same id twice");
      }
      this.seenCompletions.push(response.id);
      if (this.seenCompletions.length > HELPER_ID_REPLAY_WINDOW) {
        this.seenCompletions.shift();
      }
      const pending = this.pending;
      this.pending = null;
      if (!response.ok) {
        pending.reject(new HelperProtocolError(response.error.code, response.error.message));
        return;
      }
      pending.resolve(response.result);
    } catch (err) {
      this.signalFailure(err, true);
    }
  }

  private rejectPending(err: unknown): void {
    if (!this.pending) return;
    const pending = this.pending;
    this.pending = null;
    pending.reject(err);
  }

  /**
   * Reader/abort/dispatch entry. Must not await the cleanup task that joins
   * those same callbacks.
   */
  private signalFailure(err: unknown, kill: boolean): void {
    try {
      this.writerAbort?.abort();
    } catch {
      // writer already cancelled
    }
    this.requestCancel?.reject(err);
    if (this.state === "closed" && !this.owned) {
      this.rejectPending(err);
      return;
    }
    if (this.state !== "failed" && this.state !== "closing") this.state = "failed";
    if (!this.failError) this.failError = err;
    this.rejectPending(err);
    this.startCleanup(kill);
  }

  private startCleanup(kill: boolean): Promise<void> {
    if (this.cleanupTask) return this.cleanupTask;
    this.cleanupTask = this.runCleanup(kill);
    this.observe(this.cleanupTask);
    return this.cleanupTask;
  }

  private async joinCleanup(original: unknown): Promise<void> {
    const task = this.cleanupTask ?? this.startCleanup(true);
    try {
      await task;
    } catch (cleanupErr) {
      this.cleanupError = this.cleanupError ?? cleanupErr;
      retainCleanupFailure(original, this.cleanupError);
    }
  }

  private async runCleanup(kill: boolean): Promise<void> {
    this.clearAbort();
    this.rejectPending(this.failError ?? new HelperClosedError("failed", "helper transport failed"));
    const owned = this.owned;
    const stdout = this.stdoutReader;
    const stderr = this.stderrReader;
    this.stdoutReader = null;
    this.stderrReader = null;

    if (owned) {
      try {
        const ended = owned.stdin.end?.();
        if (ended !== undefined && typeof ended !== "number") this.observe(Promise.resolve(ended).then(() => undefined));
      } catch {
        // stdin may already be closed
      }
      if (kill && owned.exitCode === null && !this.exitConfirmed) {
        try {
          owned.kill();
        } catch {
          // process may have already exited
        }
      }
    }

    if (stdout) {
      try {
        this.observe(stdout.cancel());
      } catch {
        // ignore
      }
    }
    if (stderr) {
      try {
        this.observe(stderr.cancel());
      } catch {
        // ignore
      }
    }

    const joinReaders = Promise.allSettled([this.stdoutTask ?? Promise.resolve(), this.stderrTask ?? Promise.resolve()]);
    const readerTimeout = new Timeout(this.shutdownTimeoutMs, "reader_deadline", "timed out joining helper readers");
    try {
      await Promise.race([joinReaders.then(() => undefined), readerTimeout.promise]);
    } catch {
      // readers are bounded; continue to wait for the owned process
    } finally {
      readerTimeout.clear();
    }
    this.stdoutTask = null;
    this.stderrTask = null;

    if (!owned) return;
    if (this.exitConfirmed || owned.exitCode !== null) {
      this.exitConfirmed = true;
      this.lastPid = owned.pid;
      this.owned = null;
      this.pid = null;
      return;
    }

    const exitTimeout = new Timeout(this.shutdownTimeoutMs, "reap_deadline", "timed out waiting for helper exit");
    try {
      await Promise.race([owned.exited, exitTimeout.promise]);
      this.exitConfirmed = true;
      this.lastPid = owned.pid;
      this.owned = null;
      this.pid = null;
    } catch (err) {
      try {
        owned.kill();
      } catch {
        // still unconfirmed
      }
      this.lastPid = owned.pid;
      this.pid = owned.pid;
      this.cleanupError = err;
      throw new HelperClosedError("cleanup_failed", "helper exit was not confirmed; retaining owned handle and pid", {
        cleanupFailure: err,
      });
    } finally {
      exitTimeout.clear();
    }
  }

  private observe(promise: Promise<unknown>): void {
    promise.then(
      () => undefined,
      () => undefined,
    );
  }

  private clearAbort(): void {
    if (this.abortCleanup) {
      this.abortCleanup();
      this.abortCleanup = null;
    }
  }

  private resetSession(): void {
    this.failError = null;
    this.cleanupError = null;
    this.seq = 0;
    this.seenCompletions = [];
    this.stderrBytes = 0;
    this.pending = null;
    this.inflight = null;
    this.closePromise = null;
    this.cleanupTask = null;
    this.decoder = null;
    this.exitConfirmed = false;
    this.writerAbort = null;
    this.requestCancel = null;
  }
}

function listenOnce(signal: AbortSignal | undefined, onAbort: () => void): () => void {
  if (!signal) return () => undefined;
  let settled = false;
  const run = (): void => {
    if (settled) return;
    settled = true;
    onAbort();
  };
  if (signal.aborted) {
    run();
    return () => undefined;
  }
  signal.addEventListener("abort", run, { once: true });
  return () => {
    settled = true;
    signal.removeEventListener("abort", run);
  };
}

function combineSignals(a?: AbortSignal, b?: AbortSignal): AbortSignal | undefined {
  if (!a) return b;
  if (!b) return a;
  if (typeof AbortSignal.any === "function") return AbortSignal.any([a, b]);
  return a;
}

export function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
