import type { DiagnosticErrorBody } from "./types.js";

export class LocalRuntimeError extends Error {
  readonly code: string;
  readonly httpStatus: number | undefined;
  cleanupFailure: unknown;

  constructor(
    code: string,
    message: string,
    options?: ErrorOptions & { httpStatus?: number; cleanupFailure?: unknown },
  ) {
    super(message, options);
    this.name = "LocalRuntimeError";
    this.code = code;
    this.httpStatus = options?.httpStatus;
    this.cleanupFailure = options?.cleanupFailure;
  }
}

export class SandboxUnavailableError extends LocalRuntimeError {
  readonly diagnostic: DiagnosticErrorBody;
  readonly provenance: "helper" | "remote" | "local";

  constructor(options: {
    message: string;
    diagnostic: DiagnosticErrorBody;
    httpStatus?: number;
    provenance: "helper" | "remote" | "local";
    cause?: unknown;
    cleanupFailure?: unknown;
  }) {
    const base: ErrorOptions & { httpStatus?: number; cleanupFailure?: unknown } = {};
    if (options.cause !== undefined) base.cause = options.cause;
    if (options.httpStatus !== undefined) base.httpStatus = options.httpStatus;
    if (options.cleanupFailure !== undefined) base.cleanupFailure = options.cleanupFailure;
    super("execution_unavailable", options.message, base);
    this.name = "SandboxUnavailableError";
    this.diagnostic = options.diagnostic;
    this.provenance = options.provenance;
  }
}

export class HelperProtocolError extends LocalRuntimeError {
  constructor(code: string, message: string, options?: ErrorOptions & { httpStatus?: number; cleanupFailure?: unknown }) {
    super(code, message, options);
    this.name = "HelperProtocolError";
  }
}

export class HelperStartupError extends LocalRuntimeError {
  constructor(code: string, message: string, options?: ErrorOptions & { httpStatus?: number; cleanupFailure?: unknown }) {
    super(code, message, options);
    this.name = "HelperStartupError";
  }
}

export class HelperClosedError extends LocalRuntimeError {
  constructor(code: string, message: string, options?: ErrorOptions & { httpStatus?: number; cleanupFailure?: unknown }) {
    super(code, message, options);
    this.name = "HelperClosedError";
  }
}

export class HelperVersionError extends LocalRuntimeError {
  constructor(code: string, message: string, options?: ErrorOptions & { httpStatus?: number; cleanupFailure?: unknown }) {
    super(code, message, options);
    this.name = "HelperVersionError";
  }
}

export class HelperBusyError extends LocalRuntimeError {
  constructor(message = "one in-flight helper request is allowed; concurrent requests are rejected") {
    super("busy", message);
    this.name = "HelperBusyError";
  }
}

export function retainCleanupFailure<T>(err: T, cleanupFailure: unknown): T {
  if (cleanupFailure === undefined) return err;
  if (err instanceof LocalRuntimeError) {
    if (err.cleanupFailure === undefined) err.cleanupFailure = cleanupFailure;
    return err;
  }
  if (err instanceof Error) {
    Object.defineProperty(err, "cleanupFailure", { value: cleanupFailure, enumerable: true, configurable: true });
  }
  return err;
}

export function isExecutionUnavailable(status: number, code: string): boolean {
  return status === 501 && code === "execution_unavailable";
}
