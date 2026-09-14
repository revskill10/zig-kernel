import {
  SandboxUnavailableError,
  HelperStartupError,
  HelperVersionError,
  LocalRuntimeError,
  isExecutionUnavailable,
  retainCleanupFailure,
} from "./errors.js";
import {
  DIAGNOSTIC_EXECUTION_UNAVAILABLE,
  frozenClone,
  parseHelperCreateUnavailableResult,
  parseHelperDiagnosticsResult,
  parseHelperHello,
  type DiagnosticCapabilities,
  type HealthDocument,
  type HelperDiagnosticsResult,
  type HelperHello,
  type LocalRuntimeState,
  type ReadyDocument,
  type SandboxCreateDefinition,
} from "./types.js";
import {
  OwnedHelperTransport,
  type LocalEngineTransport,
  type OwnedHelperOpenOptions,
} from "./transports/helper.js";

export type { LocalEngineTransport, OwnedHelperOpenOptions };

export interface LocalOpenOptions extends Partial<OwnedHelperOpenOptions> {
  helperPath?: string;
  transport?: LocalEngineTransport;
  signal?: AbortSignal;
}

/**
 * Bun-only local runtime. `LocalSandbox.open` starts an SDK-owned Zig helper
 * through an injectable {@link LocalEngineTransport}. The default
 * {@link OwnedHelperTransport} uses Bun.spawn and private pipes. A future
 * Bun-tested Node-API native adapter is a separate transport at this seam and
 * is not shipped in TS0. bun:ffi is not the production default.
 */
export class LocalSandbox implements AsyncDisposable {
  private diagnostics: HelperDiagnosticsResult | null = null;
  private hello: HelperHello | null = null;

  private constructor(private readonly transport: LocalEngineTransport) {}

  static async open(options: LocalOpenOptions): Promise<LocalSandbox> {
    if (!options) {
      throw new HelperStartupError("invalid_options", "LocalSandbox.open requires options");
    }
    const transport = options.transport ?? createOwnedTransport(options);
    const runtime = new LocalSandbox(transport);
    try {
      const rawHello = await transport.open(options.signal);
      try {
        runtime.hello = frozenClone(parseHelperHello(rawHello));
      } catch (cause) {
        if (cause instanceof HelperVersionError) throw cause;
        throw new HelperVersionError("version_mismatch", "helper hello identity is not the negotiated contract", {
          cause,
        });
      }
      runtime.diagnostics = await runtime.loadDiagnostics(options.signal);
      return runtime;
    } catch (err) {
      let cleanupFailure: unknown;
      try {
        await transport.close();
      } catch (closeErr) {
        cleanupFailure = closeErr;
      }
      throw retainCleanupFailure(err, cleanupFailure);
    }
  }

  get state(): LocalRuntimeState {
    return this.transport.state;
  }

  get helperPid(): number | null {
    return this.transport.pid;
  }

  get lastHelperPid(): number | null {
    return this.transport.lastPid;
  }

  get helloInfo(): HelperHello | null {
    return this.hello;
  }

  async health(): Promise<HealthDocument> {
    return (await this.currentDiagnostics()).health;
  }

  async ready(): Promise<{ document: ReadyDocument; status: number }> {
    const diag = await this.currentDiagnostics();
    return { document: diag.ready, status: diag.http.ready };
  }

  async capabilities(): Promise<DiagnosticCapabilities> {
    const diag = await this.currentDiagnostics();
    if (diag.capabilities.features.execution !== false) {
      throw new LocalRuntimeError(
        "unexpected_execution",
        "helper advertised execution without a qualified provider",
      );
    }
    if (diag.http.ready !== 503) {
      throw new LocalRuntimeError("unexpected_ready", "TS0 helper readiness must remain HTTP 503");
    }
    return diag.capabilities;
  }

  async create(definition: SandboxCreateDefinition, signal?: AbortSignal): Promise<never> {
    if (definition === null || typeof definition !== "object") {
      throw new LocalRuntimeError("invalid_request", "sandbox definition must be an object");
    }
    const raw = await this.transport.request("create-unavailable", { definition }, signal);
    let result: ReturnType<typeof parseHelperCreateUnavailableResult>;
    try {
      result = parseHelperCreateUnavailableResult(raw);
    } catch (cause) {
      throw new LocalRuntimeError("malformed", "create-unavailable result missing diagnostic envelope", { cause });
    }
    const diagnostic = result.body;
    if (!isExecutionUnavailable(result.status, diagnostic.error.code)) {
      throw new LocalRuntimeError(diagnostic.error.code, diagnostic.error.message, {
        httpStatus: result.status,
      });
    }
    throw new SandboxUnavailableError({
      message: diagnostic.error.message,
      diagnostic,
      httpStatus: result.status,
      provenance: "helper",
    });
  }

  /**
   * TS0 has no execution provider. This rejects with the diagnostic unavailable
   * envelope and never dispatches a helper execution method or host workload.
   */
  async exec(): Promise<never> {
    throw new SandboxUnavailableError({
      message: DIAGNOSTIC_EXECUTION_UNAVAILABLE.error.message,
      diagnostic: DIAGNOSTIC_EXECUTION_UNAVAILABLE,
      provenance: "local",
    });
  }

  async close(): Promise<void> {
    await this.transport.close();
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }

  private async currentDiagnostics(): Promise<HelperDiagnosticsResult> {
    if (this.transport.state !== "open") {
      throw new LocalRuntimeError(this.transport.state, `local runtime is ${this.transport.state}`);
    }
    if (this.diagnostics) return this.diagnostics;
    return this.loadDiagnostics();
  }

  private async loadDiagnostics(signal?: AbortSignal): Promise<HelperDiagnosticsResult> {
    const raw = await this.transport.request("diagnostics", undefined, signal);
    let result: HelperDiagnosticsResult;
    try {
      result = frozenClone(parseHelperDiagnosticsResult(raw));
    } catch (cause) {
      throw new LocalRuntimeError("unexpected_diagnostics", "helper diagnostics are not the fail-closed public route", {
        cause,
      });
    }
    if (result.http.ready !== 503 || result.capabilities.features.execution !== false) {
      throw new LocalRuntimeError("unexpected_diagnostics", "helper diagnostics are not the fail-closed public route");
    }
    this.diagnostics = result;
    return result;
  }
}

function createOwnedTransport(options: LocalOpenOptions): OwnedHelperTransport {
  if (!options.helperPath) {
    throw new HelperStartupError(
      "invalid_helper_path",
      "LocalSandbox.open requires helperPath or an injected LocalEngineTransport",
    );
  }
  const owned: OwnedHelperOpenOptions = { helperPath: options.helperPath };
  if (options.helperArgs) owned.helperArgs = options.helperArgs;
  if (options.cwd) owned.cwd = options.cwd;
  if (options.helperEnv) owned.helperEnv = options.helperEnv;
  if (options.signal) owned.signal = options.signal;
  if (options.startupTimeoutMs !== undefined) owned.startupTimeoutMs = options.startupTimeoutMs;
  if (options.requestTimeoutMs !== undefined) owned.requestTimeoutMs = options.requestTimeoutMs;
  if (options.shutdownTimeoutMs !== undefined) owned.shutdownTimeoutMs = options.shutdownTimeoutMs;
  if (options.maxFrameBytes !== undefined) owned.maxFrameBytes = options.maxFrameBytes;
  if (options.maxStdoutBytes !== undefined) owned.maxStdoutBytes = options.maxStdoutBytes;
  if (options.maxStderrBytes !== undefined) owned.maxStderrBytes = options.maxStderrBytes;
  return new OwnedHelperTransport(owned);
}

export { OwnedHelperTransport };
