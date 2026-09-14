import {
  HelperClosedError,
  LocalRuntimeError,
  SandboxUnavailableError,
  isExecutionUnavailable,
} from "./errors.js";
import {
  DEFAULT_REMOTE_TIMEOUT_MS,
  DIAGNOSTIC_EMPTY_CAPABILITIES,
  DIAGNOSTIC_EXECUTION_UNAVAILABLE,
  MAX_REMOTE_BODY_BYTES,
  MAX_TIMEOUT_MS,
  frozenClone,
  parseDiagnosticCapabilities,
  parseDiagnosticErrorBody,
  parseHealthDocument,
  parseReadyDocument,
  type DiagnosticCapabilities,
  type DiagnosticErrorBody,
  type HealthDocument,
  type ReadyDocument,
  type SandboxCreateDefinition,
} from "./types.js";

export interface RemoteTransportRequest {
  method: string;
  path: string;
  body?: string;
  signal?: AbortSignal;
}

export interface RemoteTransportResponse {
  status: number;
  body: string;
}

/**
 * Injected transport owns actual I/O. The SDK independently enforces a finite
 * client promise deadline and UTF-8 body cap, and observes late fetch
 * rejections. Honouring `signal` is how a transport cooperatively cancels
 * in-flight I/O; ignoring it does not keep the client promise pending. There
 * is no host helper or process fallback.
 */
export interface RemoteTransport {
  fetch(request: RemoteTransportRequest): Promise<RemoteTransportResponse>;
}

export interface RemoteSandboxOptions {
  transport: RemoteTransport;
  signal?: AbortSignal;
  requestTimeoutMs?: number;
  maxBodyBytes?: number;
}

function boundPositiveInt(value: number | undefined, fallback: number, max: number, label: string): number {
  const n = value ?? fallback;
  if (!Number.isInteger(n) || n <= 0 || n > max) {
    throw new LocalRuntimeError("invalid_bound", `${label} must be a finite positive integer <= ${max}`);
  }
  return n;
}

function utf8BytesExceed(text: string, maxBytes: number): boolean {
  if (text.length > maxBytes) return true;
  return new TextEncoder().encode(text).byteLength > maxBytes;
}

function assertUtf8Bound(text: string, maxBytes: number, what: string): void {
  if (typeof text !== "string") {
    throw new LocalRuntimeError("malformed", `${what} is not a string body`);
  }
  if (utf8BytesExceed(text, maxBytes)) {
    throw new LocalRuntimeError("payload_too_large", `${what} exceeded ${maxBytes} bytes`);
  }
}

function parseJsonObject(body: string, what: string, maxBytes: number): Record<string, unknown> {
  assertUtf8Bound(body, maxBytes, what);
  let value: unknown;
  try {
    value = JSON.parse(body) as unknown;
  } catch (cause) {
    throw new LocalRuntimeError("malformed", `${what} is not valid json`, { cause });
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new LocalRuntimeError("malformed", `${what} is not a json object`);
  }
  return value as Record<string, unknown>;
}

class Deadline {
  readonly promise: Promise<never>;
  private handle: ReturnType<typeof setTimeout> | undefined;
  private settled = false;

  constructor(ms: number, code: string, message: string) {
    this.promise = new Promise((_, reject) => {
      this.handle = setTimeout(() => {
        this.settled = true;
        reject(new LocalRuntimeError(code, message));
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

class OnceReject {
  readonly promise: Promise<never>;
  private rejectFn!: (reason: unknown) => void;
  private settled = false;

  constructor() {
    this.promise = new Promise<never>((_, reject) => {
      this.rejectFn = reject;
    });
  }

  reject(reason: unknown): void {
    if (this.settled) return;
    this.settled = true;
    this.rejectFn(reason);
  }
}

function observe(promise: Promise<unknown>): void {
  promise.then(
    () => undefined,
    () => undefined,
  );
}

function abortError(signal?: AbortSignal): Error {
  const err = new HelperClosedError("aborted", "operation aborted");
  if (signal?.reason !== undefined) {
    err.cause = signal.reason;
  }
  return err;
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

function parseRemoteDiagnostic(body: string, maxBytes: number): DiagnosticErrorBody {
  const value = parseJsonObject(body, "remote error", maxBytes);
  try {
    return parseDiagnosticErrorBody(value);
  } catch (cause) {
    throw new LocalRuntimeError("malformed", "remote diagnostic envelope is incomplete", { cause });
  }
}

function mergeSignal(a?: AbortSignal, b?: AbortSignal): AbortSignal | undefined {
  if (!a) return b;
  if (!b) return a;
  if (typeof AbortSignal.any === "function") return AbortSignal.any([a, b]);
  return a;
}

function throwMappedRemoteError(status: number, diagnostic: DiagnosticErrorBody, provenance: "remote"): never {
  if (isExecutionUnavailable(status, diagnostic.error.code)) {
    throw new SandboxUnavailableError({
      message: diagnostic.error.message,
      diagnostic,
      httpStatus: status,
      provenance,
    });
  }
  throw new LocalRuntimeError(diagnostic.error.code, diagnostic.error.message, { httpStatus: status });
}

/**
 * Remote/browser adapter. It never spawns a helper, VM, workload, or local
 * host-exec fallback. Callers inject HTTPS/UDS transport; this entrypoint has
 * no Bun/process import side effects.
 */
export class RemoteSandbox {
  private closed = false;
  private readonly closeAbort = new AbortController();
  private readonly transport: RemoteTransport;
  private readonly signal: AbortSignal | undefined;
  private readonly requestTimeoutMs: number;
  private readonly maxBodyBytes: number;

  constructor(options: RemoteSandboxOptions) {
    if (!options?.transport) {
      throw new LocalRuntimeError("invalid_transport", "remote transport is required");
    }
    this.transport = options.transport;
    this.signal = options.signal;
    this.requestTimeoutMs = boundPositiveInt(
      options.requestTimeoutMs,
      DEFAULT_REMOTE_TIMEOUT_MS,
      MAX_TIMEOUT_MS,
      "requestTimeoutMs",
    );
    this.maxBodyBytes = boundPositiveInt(
      options.maxBodyBytes,
      MAX_REMOTE_BODY_BYTES,
      MAX_REMOTE_BODY_BYTES,
      "maxBodyBytes",
    );
  }

  async health(signal?: AbortSignal): Promise<HealthDocument> {
    const response = await this.call("GET", "/healthz", undefined, signal);
    if (response.status !== 200) {
      this.throwHttpOrDiagnostic("health", response);
    }
    try {
      return frozenClone(parseHealthDocument(parseJsonObject(response.body, "health", this.maxBodyBytes)));
    } catch (cause) {
      if (cause instanceof LocalRuntimeError) throw cause;
      throw new LocalRuntimeError("malformed", "health document is incomplete", { cause, httpStatus: response.status });
    }
  }

  async ready(signal?: AbortSignal): Promise<{ document: ReadyDocument; status: number }> {
    const response = await this.call("GET", "/readyz", undefined, signal);
    try {
      const document = frozenClone(parseReadyDocument(parseJsonObject(response.body, "ready", this.maxBodyBytes)));
      return { document, status: response.status };
    } catch (cause) {
      if (cause instanceof LocalRuntimeError) throw cause;
      throw new LocalRuntimeError("malformed", "ready document is incomplete", { cause, httpStatus: response.status });
    }
  }

  async capabilities(signal?: AbortSignal): Promise<DiagnosticCapabilities> {
    const response = await this.call("GET", "/v1/capabilities", undefined, signal);
    if (response.status !== 200) {
      this.throwHttpOrDiagnostic("capabilities", response);
    }
    let caps: DiagnosticCapabilities;
    try {
      caps = frozenClone(parseDiagnosticCapabilities(parseJsonObject(response.body, "capabilities", this.maxBodyBytes)));
    } catch (cause) {
      if (cause instanceof LocalRuntimeError) throw cause;
      throw new LocalRuntimeError("malformed", "capabilities document is incomplete", {
        cause,
        httpStatus: response.status,
      });
    }
    if (caps.features.execution === true) {
      throw new LocalRuntimeError(
        "unexpected_execution",
        "remote advertised execution without a qualified provider; refusing to continue",
      );
    }
    return caps;
  }

  async create(definition: SandboxCreateDefinition, signal?: AbortSignal): Promise<never> {
    if (definition === null || typeof definition !== "object") {
      throw new LocalRuntimeError("invalid_request", "sandbox definition must be an object");
    }
    const response = await this.call("POST", "/v1/sandboxes", JSON.stringify(definition), signal);
    const diagnostic = parseRemoteDiagnostic(response.body, this.maxBodyBytes);
    throwMappedRemoteError(response.status, diagnostic, "remote");
  }

  async exec(): Promise<never> {
    throw new SandboxUnavailableError({
      message: DIAGNOSTIC_EXECUTION_UNAVAILABLE.error.message,
      diagnostic: DIAGNOSTIC_EXECUTION_UNAVAILABLE,
      provenance: "remote",
    });
  }

  async close(): Promise<void> {
    this.closed = true;
    if (!this.closeAbort.signal.aborted) this.closeAbort.abort();
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }

  private throwHttpOrDiagnostic(what: string, response: RemoteTransportResponse): never {
    try {
      const diagnostic = parseRemoteDiagnostic(response.body, this.maxBodyBytes);
      throwMappedRemoteError(response.status, diagnostic, "remote");
    } catch (err) {
      if (err instanceof SandboxUnavailableError || (err instanceof LocalRuntimeError && err.httpStatus !== undefined)) {
        throw err;
      }
      throw new LocalRuntimeError("remote_http", `${what} HTTP ${response.status}`, { httpStatus: response.status });
    }
  }

  private async call(
    method: string,
    path: string,
    body: string | undefined,
    signal?: AbortSignal,
  ): Promise<RemoteTransportResponse> {
    if (this.closed || this.closeAbort.signal.aborted) {
      throw new HelperClosedError("closed", "remote sandbox client is closed");
    }
    const user = mergeSignal(this.signal, signal);
    if (user?.aborted) throw abortError(user);
    if (body !== undefined) {
      assertUtf8Bound(body, this.maxBodyBytes, `remote ${path} request body`);
    }

    const deadline = new Deadline(
      this.requestTimeoutMs,
      "deadline",
      `${method} ${path} exceeded ${this.requestTimeoutMs}ms`,
    );
    const transportAbort = new AbortController();
    const extra = new OnceReject();
    observe(extra.promise);
    const stopUser = listenOnce(user, () => extra.reject(abortError(user)));
    const stopClose = listenOnce(this.closeAbort.signal, () => {
      extra.reject(new HelperClosedError("closed", "remote sandbox client is closed"));
    });
    const request: RemoteTransportRequest = {
      method,
      path,
      signal:
        typeof AbortSignal.any === "function"
          ? AbortSignal.any([transportAbort.signal, ...(user ? [user] : []), this.closeAbort.signal])
          : transportAbort.signal,
    };
    if (body !== undefined) request.body = body;

    type Race =
      | { k: "ok"; v: RemoteTransportResponse }
      | { k: "fetch-err"; e: unknown }
      | { k: "deadline" }
      | { k: "cancel"; e: unknown };
    try {
      const rawFetch = Promise.resolve().then(() => this.transport.fetch(request));
      observe(rawFetch);
      const winner = await Promise.race([
        rawFetch.then(
          (v) => ({ k: "ok", v }) as Race,
          (e) => ({ k: "fetch-err", e }) as Race,
        ),
        deadline.promise.then(
          () => ({ k: "deadline" }) as Race,
          () => ({ k: "deadline" }) as Race,
        ),
        extra.promise.then(
          () => ({ k: "cancel", e: new HelperClosedError("closed", "remote sandbox client is closed") }) as Race,
          (e) => ({ k: "cancel", e }) as Race,
        ),
      ]);
      if (winner.k === "ok") {
        if (typeof winner.v.body === "string" && utf8BytesExceed(winner.v.body, this.maxBodyBytes)) {
          throw new LocalRuntimeError("payload_too_large", `remote ${path} body exceeded ${this.maxBodyBytes} bytes`, {
            httpStatus: winner.v.status,
          });
        }
        return winner.v;
      }
      if (!transportAbort.signal.aborted) transportAbort.abort();
      if (winner.k === "deadline" || deadline.timedOut) {
        throw new LocalRuntimeError("deadline", `${method} ${path} exceeded ${this.requestTimeoutMs}ms`);
      }
      if (winner.k === "cancel") throw winner.e;
      if (user?.aborted) throw abortError(user);
      if (this.closed || this.closeAbort.signal.aborted) {
        throw new HelperClosedError("closed", "remote sandbox client is closed");
      }
      if (deadline.timedOut) {
        throw new LocalRuntimeError("deadline", `${method} ${path} exceeded ${this.requestTimeoutMs}ms`);
      }
      const err = winner.e;
      throw err instanceof Error ? err : new LocalRuntimeError("transport", String(err));
    } finally {
      stopUser();
      stopClose();
      deadline.clear();
      extra.reject(new HelperClosedError("closed", "remote call finished"));
    }
  }
}

export const REMOTE_DIAGNOSTIC_CAPABILITIES = DIAGNOSTIC_EMPTY_CAPABILITIES;
