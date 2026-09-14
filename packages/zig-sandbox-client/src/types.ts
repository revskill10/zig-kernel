/** TS0 public wire types. Numeric counters that may exceed JS safe integers stay decimal strings. */

import { HelperVersionError } from "./errors.js";

export const SDK_API_VERSION = "v1";
export const SDK_CONTRACT_VERSION = "1";
export const SDK_HELPER_PROTOCOL = "sdk-helper/1";
export const SDK_PACKAGE_VERSION = "0.1.0-ts0";
export const SDK_HELPER_NAME = "zig-sandbox-helper";
export const SDK_HELPER_VERSION = "0.1.0-ts0";
export const MAX_JSON_BYTES = 64 * 1024;
export const MAX_ID_BYTES = 128;
/** Session-total stdout/stderr caps for one owned helper lifetime. */
export const MAX_STDERR_BYTES = 64 * 1024;
export const MAX_STDOUT_BYTES = 256 * 1024;
export const DEFAULT_STARTUP_TIMEOUT_MS = 5_000;
export const DEFAULT_REQUEST_TIMEOUT_MS = 5_000;
export const DEFAULT_SHUTDOWN_TIMEOUT_MS = 2_000;
export const MAX_TIMEOUT_MS = 60_000;
export const MAX_QUEUED_REQUESTS = 0;
/** Diagnostic-only helper/SDK replay window. Not session-wide request uniqueness. */
export const HELPER_ID_REPLAY_WINDOW = 32;
export const MAX_REQUEST_SEQUENCE = Number.MAX_SAFE_INTEGER;
export const DEFAULT_REMOTE_TIMEOUT_MS = DEFAULT_REQUEST_TIMEOUT_MS;
export const MAX_REMOTE_BODY_BYTES = MAX_JSON_BYTES;

export type HelperMethod = "hello" | "diagnostics" | "create-unavailable" | "shutdown";

export type LocalRuntimeState = "starting" | "open" | "closing" | "closed" | "failed";

export interface DiagnosticCapabilities {
  backends: unknown[];
  guest_abis: unknown[];
  images: unknown[];
  features: {
    execution: boolean;
    network_modes: unknown[];
    snapshots: boolean;
    forks: boolean;
    sse: boolean;
  };
  ceilings: Record<string, unknown>;
}

export interface HealthDocument {
  status: string;
}

export interface ReadyDocument {
  status: string;
  reason?: string;
}

export interface DiagnosticErrorBody {
  error: {
    code: string;
    message: string;
  };
}

export interface SandboxImageRef {
  id: string;
  digest: string;
}

export interface SandboxCreateDefinition {
  profile: string;
  image: SandboxImageRef;
  limits?: Record<string, string>;
  network?: { mode: string };
  rootfs?: { mode: string; volume?: string };
}

export interface HelperHello {
  protocol: string;
  contract_version: string;
  api_version: string;
  helper: string;
  helper_version: string;
}

export interface HelperHttpStatuses {
  health: number;
  ready: number;
  capabilities: number;
}

export interface HelperDiagnosticsResult {
  health: HealthDocument;
  ready: ReadyDocument;
  capabilities: DiagnosticCapabilities;
  http: HelperHttpStatuses;
}

export interface HelperCreateUnavailableResult {
  status: number;
  body: DiagnosticErrorBody;
}

export interface HelperErrorBody {
  code: string;
  message: string;
}

export type HelperResponse =
  | { ok: true; v: string; id: string; result: unknown }
  | { ok: false; v: string; id: string; error: HelperErrorBody };

export const DIAGNOSTIC_EMPTY_CAPABILITIES: DiagnosticCapabilities = {
  backends: [],
  guest_abis: [],
  images: [],
  features: {
    execution: false,
    network_modes: [],
    snapshots: false,
    forks: false,
    sse: false,
  },
  ceilings: {},
};

export const DIAGNOSTIC_EXECUTION_UNAVAILABLE: DiagnosticErrorBody = {
  error: {
    code: "execution_unavailable",
    message: "sandbox execution is not implemented in this bootstrap",
  },
};

export function isOpaqueId(value: string): boolean {
  if (value.length < 1 || value.length > MAX_ID_BYTES) return false;
  let allDigits = true;
  for (let i = 0; i < value.length; i += 1) {
    const c = value.charCodeAt(i);
    const ok =
      (c >= 65 && c <= 90) ||
      (c >= 97 && c <= 122) ||
      (c >= 48 && c <= 57) ||
      c === 46 ||
      c === 95 ||
      c === 45 ||
      c === 58;
    if (!ok) return false;
    if (c < 48 || c > 57) allDigits = false;
  }
  return !allDigits;
}

export function isCanonicalDecimalU64(value: string): boolean {
  if (value.length === 0 || value.length > 20) return false;
  if (value.charCodeAt(0) === 48) return value.length === 1;
  for (let i = 0; i < value.length; i += 1) {
    const c = value.charCodeAt(i);
    if (c < 48 || c > 57) return false;
  }
  try {
    const n = BigInt(value);
    return n >= 0n && n <= 18446744073709551615n;
  } catch {
    return false;
  }
}

export function isDiagnosticEnvelope(bytes: string): boolean {
  return bytes.includes('{"error":{"code":');
}

export function isCanonicalEnvelope(bytes: string): boolean {
  return bytes.includes('"request_id"') && bytes.includes('"retryable"') && !isDiagnosticEnvelope(bytes);
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function failShape(message: string): never {
  throw new Error(message);
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0) failShape(`${label} must be a non-empty string`);
  return value;
}

function requiredBoolean(value: unknown, label: string): boolean {
  if (typeof value !== "boolean") failShape(`${label} must be a boolean`);
  return value;
}

function requiredArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) failShape(`${label} must be an array`);
  return value;
}

function requiredObject(value: unknown, label: string): Record<string, unknown> {
  if (!isRecord(value)) failShape(`${label} must be an object`);
  return value;
}

function requiredHttpStatus(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 100 || value > 599) {
    failShape(`${label} must be an HTTP status integer`);
  }
  return value;
}

export function parseHealthDocument(value: unknown): HealthDocument {
  const rec = requiredObject(value, "health");
  return { status: requiredString(rec.status, "health.status") };
}

export function parseReadyDocument(value: unknown): ReadyDocument {
  const rec = requiredObject(value, "ready");
  const document: ReadyDocument = { status: requiredString(rec.status, "ready.status") };
  if (rec.reason !== undefined) document.reason = requiredString(rec.reason, "ready.reason");
  return document;
}

export function parseDiagnosticCapabilities(value: unknown): DiagnosticCapabilities {
  const rec = requiredObject(value, "capabilities");
  const featuresRec = requiredObject(rec.features, "capabilities.features");
  return {
    backends: requiredArray(rec.backends, "capabilities.backends"),
    guest_abis: requiredArray(rec.guest_abis, "capabilities.guest_abis"),
    images: requiredArray(rec.images, "capabilities.images"),
    features: {
      execution: requiredBoolean(featuresRec.execution, "features.execution"),
      network_modes: requiredArray(featuresRec.network_modes, "features.network_modes"),
      snapshots: requiredBoolean(featuresRec.snapshots, "features.snapshots"),
      forks: requiredBoolean(featuresRec.forks, "features.forks"),
      sse: requiredBoolean(featuresRec.sse, "features.sse"),
    },
    ceilings: requiredObject(rec.ceilings, "capabilities.ceilings"),
  };
}

export function parseDiagnosticErrorBody(value: unknown): DiagnosticErrorBody {
  const rec = requiredObject(value, "diagnostic");
  const nested = requiredObject(rec.error, "diagnostic.error");
  return {
    error: {
      code: requiredString(nested.code, "diagnostic.error.code"),
      message: requiredString(nested.message, "diagnostic.error.message"),
    },
  };
}

export function parseHelperHello(value: unknown): HelperHello {
  const rec = requiredObject(value, "hello");
  const hello: HelperHello = {
    protocol: requiredString(rec.protocol, "hello.protocol"),
    contract_version: requiredString(rec.contract_version, "hello.contract_version"),
    api_version: requiredString(rec.api_version, "hello.api_version"),
    helper: requiredString(rec.helper, "hello.helper"),
    helper_version: requiredString(rec.helper_version, "hello.helper_version"),
  };
  if (hello.protocol !== SDK_HELPER_PROTOCOL) {
    throw new HelperVersionError("version_mismatch", `hello protocol ${hello.protocol} != ${SDK_HELPER_PROTOCOL}`);
  }
  if (hello.contract_version !== SDK_CONTRACT_VERSION) {
    throw new HelperVersionError("version_mismatch", "hello contract_version mismatch");
  }
  if (hello.api_version !== SDK_API_VERSION) {
    throw new HelperVersionError("version_mismatch", "hello api_version mismatch");
  }
  if (hello.helper.length > MAX_ID_BYTES || hello.helper_version.length > MAX_ID_BYTES) {
    failShape("hello helper identity exceeds bound");
  }
  if (hello.helper !== SDK_HELPER_NAME || hello.helper_version !== SDK_HELPER_VERSION) {
    throw new HelperVersionError(
      "version_mismatch",
      `helper identity ${hello.helper}@${hello.helper_version} != ${SDK_HELPER_NAME}@${SDK_HELPER_VERSION}`,
    );
  }
  return hello;
}

export function parseHelperHttpStatuses(value: unknown): HelperHttpStatuses {
  const rec = requiredObject(value, "http");
  return {
    health: requiredHttpStatus(rec.health, "http.health"),
    ready: requiredHttpStatus(rec.ready, "http.ready"),
    capabilities: requiredHttpStatus(rec.capabilities, "http.capabilities"),
  };
}

export function parseHelperDiagnosticsResult(value: unknown): HelperDiagnosticsResult {
  const rec = requiredObject(value, "diagnostics");
  return {
    health: parseHealthDocument(rec.health),
    ready: parseReadyDocument(rec.ready),
    capabilities: parseDiagnosticCapabilities(rec.capabilities),
    http: parseHelperHttpStatuses(rec.http),
  };
}

export function parseHelperCreateUnavailableResult(value: unknown): HelperCreateUnavailableResult {
  const rec = requiredObject(value, "create-unavailable");
  return {
    status: requiredHttpStatus(rec.status, "create-unavailable.status"),
    body: parseDiagnosticErrorBody(rec.body),
  };
}

export function frozenClone<T>(value: T): T {
  return deepFreeze(JSON.parse(JSON.stringify(value)) as T);
}

function deepFreeze<T>(value: T): T {
  if (value !== null && typeof value === "object") {
    Object.freeze(value);
    for (const inner of Object.values(value as Record<string, unknown>)) {
      deepFreeze(inner);
    }
  }
  return value;
}
