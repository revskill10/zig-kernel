# `@zig-sandbox/sdk` (TS0)

Private local prerelease. This is a Bun 1.4.2 TypeScript library that can talk
to the fail-closed remote diagnostics API and, in `/local`, own a compiled Zig
userspace helper over private stdio pipes. **Sandbox execution is unavailable.**
It is not an npm registry package, not a production sandbox, not Alpine, and
not a desktop.

Intended hosts for this slice: Windows x64 and Linux x64 with pinned Bun 1.4.2
and Zig 0.16.0. Those hosts are **unverified in this source tree** until the
root Windows/Linux matrix actually passes and retains receipts. Cross-compile
and writer assertion do not qualify a host. Node, Deno, macOS, and ARM are
not qualified.

## Build the helper (required for `/local`)

From the repository root, with Zig 0.16.0:

```sh
zig build sandbox-helper
```

The opt-in binary is `zig-out/bin/zig-sandbox-helper` (`.exe` on Windows).
`helperPath` must be that **trusted absolute path**. TS0 does not search PATH,
expand `~`, download a helper at install time, or fall back to host exec.

Protocol tests without spawning the binary:

```sh
zig build test-sdk-helper
```

## Install the private tarball

There is no registry publish. Pack and install from a local tarball only.
`bun pm pack --destination` is the supported pack form; do not combine
`--destination` and `--filename` (Bun 1.4.2 rejects that).

From the repository root, after `zig build sandbox-helper`:

```sh
cd packages/zig-sandbox-client
bun install --frozen-lockfile
bun run build
bun pm pack --destination /abs/path/to/pack-dir --ignore-scripts
```

Use an explicit destination directory you own. The tarball name is
`zig-sandbox-sdk-0.1.0-ts0.tgz`. A consumer then:

```sh
mkdir consumer && cd consumer
cat > package.json <<'EOF'
{
  "name": "sdk-consumer",
  "private": true,
  "type": "module",
  "dependencies": {
    "@zig-sandbox/sdk": "file:../zig-sandbox-sdk-0.1.0-ts0.tgz"
  }
}
EOF
bun install
```

For declaration/dev checks, pin the same toolchain already frozen in this
package (`typescript@7.0.2`, `@types/bun@1.4.2`) via this package's `bun.lock`
closure rather than a fresh unbounded resolve.

The package `files` allowlist ships `dist` JS + declarations, `README.md`, and
`package.json` only. Root import is environment-neutral (`types`, `errors`,
`remote`) and has no Bun/process side effects. `/local` is Bun-only.

## Local mode

```ts
import { LocalSandbox } from "@zig-sandbox/sdk/local";
import { SandboxUnavailableError } from "@zig-sandbox/sdk";

const helperPath = "D:/path/to/zig-out/bin/zig-sandbox-helper.exe";
const runtime = await LocalSandbox.open({ helperPath });
try {
  const caps = await runtime.capabilities();
  console.log(caps.features.execution); // false
  const ready = await runtime.ready(); // HTTP 503 diagnostic
  try {
    await runtime.create({
      profile: "linux-vm/x64",
      image: { id: "example", digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" },
    });
  } catch (err) {
    if (err instanceof SandboxUnavailableError) {
      // diagnostic envelope from the helper; no invented resource/request ids
    }
  }
} finally {
  await runtime.close(); // idempotent; close again is a no-op
}
```

`LocalSandbox.open` starts exactly one owned helper via `Bun.spawn` (argv
array, `windowsHide: true`, private pipes, minimal environment, explicit cwd)
and owns cleanup across hello + diagnostics. `startupTimeoutMs` bounds the
hello request on those pipes after spawn returns; it cannot preempt a
synchronous native `Bun.spawn` call. A cold Windows helper image start can
block inside spawn for tens of seconds; a warmed repeat start is milliseconds.
Request deadlines begin at the actual private-pipe write/flush/reply. Injected
`LocalEngineTransport` implementations must return the negotiated hello
(`zig-sandbox-helper` / `0.1.0-ts0`); `open` parses and frozen-clones it even
for an injected transport and closes the transport if validation fails. `create`
/ `exec` stay typed `SandboxUnavailableError` only for HTTP 501 plus
`execution_unavailable`. `exec` never dispatches a workload method. One
in-flight helper request is allowed; concurrent calls reject `busy`.
`AbortSignal` settles once and fail-closes pending helper authority. `close`
stops admissions, settles pending work, sends `shutdown`, then kills the
**Bun-owned subprocess handle** if needed and awaits the actual exit. The
helper owns no children in TS0. A transport is one lifecycle: do not open
again while previous ownership is unresolved. A future Bun-tested Node-API
adapter still implements this named `LocalEngineTransport` contract; unknown
helper names or versions are not implicitly compatible.

## Remote mode

```ts
import { RemoteSandbox } from "@zig-sandbox/sdk/remote";

const client = new RemoteSandbox({ transport });
await client.capabilities();
await client.create(definition); // typed unavailable; never falls back to local
```

`/remote` never spawns a helper, VM, or host process. Browser/Node remote
consumers remain transport-injected HTTP/UDS only. The SDK independently
settles each call with a finite promise deadline (`requestTimeoutMs`, default
5000ms) and a UTF-8 byte body cap (`maxBodyBytes`, default 64KiB, inbound and
outbound). `AbortSignal.timeout` is not the promise deadline. The SDK passes
`AbortSignal` so a cooperative transport can cancel in-flight I/O; a transport
that ignores it is still failed by the client deadline, and late fetch
rejections are observed. Actual I/O cancellation requires transport
cooperation. Pre-aborted calls do not invoke the transport. `close` aborts and
settles this client's pending calls. There is no implicit host fallback.

## Limits (TS0)

- No execution provider, Store, guest Linux, PTY, or networking.
- No signed platform helper packages; pass `helperPath` yourself.
- Helper protocol `sdk-helper/1` is private length-prefixed UTF-8 JSON.
- TS0 hello identity is exact `zig-sandbox-helper` / `0.1.0-ts0`. Unknown
  helper names or versions fail as `HelperVersionError`.
- First request must be `hello`; hello cannot repeat. After `shutdown` the
  helper process exits.
- Request ids: SDK sequences `req_1`… with bounded bookkeeping up to
  `Number.MAX_SAFE_INTEGER`. The helper keeps a rolling 32-id history as a
  **diagnostic-only replay window**, not session-wide uniqueness.
- Session-total stdout cap 256KiB, stderr cap 64KiB, frame/JSON cap 64KiB.
- Default timeouts: startup 5s, request 5s, shutdown/reap 2s, max 60s.
  Request deadlines cover write+flush+reply from the start of the private-pipe
  operation. Process termination is a separate bounded cleanup. Spawn itself
  is not preempted by those timers.
- Diagnostics remain `features.execution: false` and readiness 503.
- Only status 501 + `execution_unavailable` maps to `SandboxUnavailableError`.
  401/403/409/500 and other protocol errors stay typed as themselves.

## Later work (not this package slice)

Production platform binary signing/packaging and provider/Store policy; Linux
guest execution and act-in-guest same-conformance; optional in-process
Node-API; portable Wasm core and guest Wasm as separate tracks.
