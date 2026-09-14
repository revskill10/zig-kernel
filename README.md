# Zig Kernel

Zig 0.16.0 hosted kernel simulation, i386 QEMU demo, native x86_64 UEFI
bootstrap, supervisor component tests, and a Linux/amd64 fail-closed sandbox
diagnostic HTTP listener. Companion to
`@12-factor-agents/linux-kernel-architecture.md`. Hosted models are not
Linux ABI or hardware qualification. The API is diagnostics only.

## Functionality

| Surface | Today | Planned / not runnable here |
| --- | --- | --- |
| Hosted `zig-kernel` | Native sim: paging, VFS, loopback net, scheduler | Linux ABI, hardware, production isolation |
| i386 QEMU | `qemu-bin` ELF32 demo | Linux userspace |
| Native x86_64 UEFI | PE32+ loader, ELF64 payload, FAT16 ESP, smoke initramfs | CPL3 userspace, Linux ABI, Alpine rootfs, desktop, production isolation |
| Supervisor | Hosted tests: policy, session, workspace, API, QEMU args, portable contract | Process lifecycle, Unix-socket server, guest qualification |
| Sandbox API (`zig-sandbox`) | Linux/amd64: `/healthz` 200, `/readyz` 503, capabilities `execution:false`, `/v1/sandboxes*` 501 | Client CLI; TypeScript SDK; Wasm SDK and guest Wasm; pluggable providers; host mounts; pause/resume |
| Docker API image | Loopback `-p 127.0.0.1:HOST:8080`, unprivileged `sandbox` user, no KVM | Privileged or KVM execution |

## Quick start (Zig 0.16.0)

```sh
zig build run    # hosted sim (Windows/Linux, no QEMU)
zig build test
zig build        # zig-out/bin/zig-kernel
zig build test-supervisor
```

`run` prints a VFS read of `/hello.txt` (33B) and an e1000 loopback recv (72B).
The e1000 path is a hosted simulation of descriptor rings and `netif_rx`, not a
real PCI/MMIO hardware driver.

i386 QEMU (not Linux userspace):

```sh
zig build qemu-bin -Doptimize=ReleaseSmall   # zig-out/bin/kernel-baremetal
bash scripts/qemu-x86_64.sh                  # Linux with QEMU
```

Guide: [docs/qemu-verification-guide.md](docs/qemu-verification-guide.md).
The image is a standalone freestanding kernel demo. It does not boot Linux
userspace or provide production isolation.

## Native x86_64 UEFI bootstrap

Opt-in first slice: PE32+ UEFI loader, ELF64 payload at 2 MiB, 64 MiB FAT16
ESP, and a 108-byte `INITRMF1` smoke envelope. It does **not** enter CPL3,
implement a Linux ABI, boot Alpine or any other rootfs, or provide desktop
or production isolation. Hosted `zig build` / `zig build test` remain the
default simulation path above.

```sh
zig build native-image
zig build native-tools
zig build test-native
zig build test-native-qualification
```

`native-image` installs `BOOTX64.efi`, `zk-kernel`, `native/initramfs.bin`, and
`native/esp.img`. `native-tools` builds `mkinitramfs`, `mkesp`, and `imginfo`.
`test-native` is hosted contract tests (no QEMU). `test-native-qualification`
runs host fixtures for the public qualifier (no guest).

The public qualifier (`scripts/qualify-native/qualify.py`) requires the exact
pinned verifier image and OVMF hashes in `scripts/qualify-native/probe.py`. A
missing Docker daemon, missing pin, or a fresh unpinned image is
**unavailable**, not a pass. This repository does not publish or rebuild that
image. See [docs/native-bootstrap.md](docs/native-bootstrap.md) for ESP paths,
QEMU TCG expectations, and the current qualification boundary.

## Sandbox API (diagnostics)

Linux/amd64 listener for reachability and fail-closed checks. It does not
create sandboxes, run workloads, authenticate, or isolate guests. `serve` is
the bootstrap CLI only. Docker maps loopback only; do not grant KVM or
privileged host access:

```sh
docker build -t zig-sandbox-bootstrap:local .
docker run --rm --name zig-sandbox-bootstrap \
  -p 127.0.0.1:8080:8080 zig-sandbox-bootstrap:local
```

Use `-p 127.0.0.1:HOST:8080`; do not override the image command
(`zig-sandbox serve --host=0.0.0.0 --port=8080`). Direct Linux:

```sh
zig build sandbox-api -Doptimize=ReleaseSafe
./zig-out/bin/zig-sandbox serve --host=127.0.0.1 --port=8080
```

CLI: `serve`, `--host=ADDR`, `--port=PORT`, `--help`, `--version`.

```sh
curl -i http://127.0.0.1:8080/healthz
curl -i http://127.0.0.1:8080/readyz
curl -i http://127.0.0.1:8080/v1/capabilities
curl -i -X POST --data '{"image":"example"}' \
  http://127.0.0.1:8080/v1/sandboxes
```

| Method / path | Status | Meaning |
| --- | --- | --- |
| `GET`/`HEAD /healthz` | 200 | Process is listening |
| `GET`/`HEAD /readyz` | 503 | Execution unavailable |
| `GET`/`HEAD /v1/capabilities` | 200 | `features.execution` is `false` |
| `/v1/sandboxes` and descendants | 501 | Nested `{"error":{"code","message"}}` |

Do not retry 501 or fall back to a host process. A healthy container healthcheck
is liveness only; it is not execution readiness.

The fetch example is server-side JavaScript (Node with `fetch`); browser
integrations need a same-origin proxy because diagnostic bootstrap provides
no CORS.

```js
async function sandboxDiagnostics(baseUrl) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), 5_000);
  try {
    const r = await fetch(`${baseUrl}/v1/capabilities`, { signal: c.signal });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const cap = await r.json();
    if (cap.features?.execution !== true) {
      throw new Error("sandbox execution is unavailable; do not fall back to host execution");
    }
    return cap;
  } finally { clearTimeout(t); }
}
sandboxDiagnostics("http://127.0.0.1:8080").catch((e) => console.error(e.message));
```

This bootstrap throws that error. Tests: `zig build test-sandbox`. Probe:
`bash scripts/sandbox-probe.sh`. OpenAPI is the portable planned contract, not
evidence every listed route executes.

## Roadmap

Not in this checkout: client CLI, execution providers, TypeScript and
embedded Wasm SDKs, pause/resume, durable checkpoints, guest-local CI, or
Linux/Alpine/Vinix/desktop/Photon products.

Plans only (not runnable):
[checkpoints](docs/sandbox-checkpoints.md),
[local CI](docs/sandbox-local-ci.md),
[smolvm features](audits/smolvm-features.md).

## Docs

- [architecture](docs/architecture.md) — hosted layering and data flow
- [driver guide](docs/driver-guide.md) — simulated e1000 walk
- [native bootstrap](docs/native-bootstrap.md) — UEFI/ELF slice and qualifier
- [QEMU](docs/qemu-verification-guide.md) — i386 demo verification
- [OpenAPI](docs/sandbox-api.openapi.yaml) — diagnostic/planned contract
- [implementation](docs/sandbox-api-implementation.md) — published diagnostic slice
- [checkpoints](docs/sandbox-checkpoints.md) — planned capture/store/restore
- [local CI](docs/sandbox-local-ci.md) — planned act-in-guest
- [smolvm features](audits/smolvm-features.md) — upstream source inventory

Plans and acceptance contracts (planned / not implemented; not a production
runtime):

- Audits: [sandbox](audits/sandbox.md), [sandbox API](audits/sandbox-api.md),
  [kernel/distro](audits/kernel-distro.md)
- Desktop / Photon: [desktop distro](docs/desktop-distro.md),
  [Photon Studio](docs/photon-studio.md),
  [Photon contract](tests/native-distro/photon-studio/manifest.json)
  (`not_run` / `blocked_prerequisites`)
