# Photon Studio native acceptance contract

This directory is an **acceptance contract**, not run evidence. It remains a contract until an executable native qualification exists on a booted zig-kernel ISO with real Flatpak/OSTree/bubblewrap.

**Do not read any file here as a pass.** There is no `passed` record, no run-id directory, and no native execution claim.

| Item | Value |
| --- | --- |
| Gate | **PHOTON-1** (mandatory **production release blocker**) |
| Implementation | **not implemented** |
| Qualification | **not_run** / **blocked_prerequisites** |
| Machine-readable spec | [manifest.json](manifest.json) |
| Human spec | [docs/photon-studio.md](../../../docs/photon-studio.md) |
| Desktop plan | [docs/desktop-distro.md](../../../docs/desktop-distro.md) |
| Audit | [audits/kernel-distro.md §16.4](../../../audits/kernel-distro.md#164-photon-studio-flatpak-mandatory-production-gate-photon-001-added-2026-09-13) |

## Artifact identity

Operators supply a local path to this file. Public identity is basename + size + hash (no personal absolute path required in product docs):

- Basename: `Photon-Studio-0.1.5-linux-x64.flatpak`
- Size: `282701144` bytes (282.7 MB decimal / 269.6 MiB)
- SHA-256: `49db545b57e9f6c01c063a7f90e774c446a20d10f95b2943263ae5154c077f6a`
- Header ref: `app/com.tenzen.photon/x86_64/stable`

Do **not** copy the 282701144-byte bundle into this repository or the ISO without a recorded license/distribution basis (none is claimed). Filename version is not signed provenance.

## What the header actually says

Observed by raw header scan (not a `flatpak run`, not an authenticated signature, not a complete OSTree/ELF scan):

- App `com.tenzen.photon`; command `electron-wrapper`
- Runtime `org.freedesktop.Platform/x86_64/25.08`
- SDK and Electron2 BaseApp metadata are **not** automatic extra launch-runtime installs
- Sockets: **x11** and **pulseaudio** (no Wayland socket declared)
- Device: **dri**; shared: **network** and **ipc**
- Filesystems: **home**, **/media**, **/run/media** (home is granted; do not claim home isolation). Denial tests use **selected protected host paths** outside those authorized host mounts; `/app`, `/usr`, and necessary virtual filesystems are valid runtime mounts, not automatic denials.
- Debug extension `com.tenzen.photon.Debug` is no-autodownload/autodelete — not a launch runtime

Platform/GL/font/locale **commits are unknown** until dependency resolution. Do not invent them. Exact Electron/Chromium versions are unknown. This blob is x86_64; ARM/Windows/Mac support is not proven.

## How a future native run must look

Launch `flatpak run com.tenzen.photon` and the desktop menu entry as an ordinary user on the **exact native ISO**. Preserve and inspect the declared entrypoint. **Do not add** `--no-sandbox` or extra `--filesystem=host` as an acceptance shortcut. Do not execute an extracted binary as the shortcut. The upstream wrapper implementation is unknown; do not invent a proven Chromium-inner sandbox. Flatpak outer containment must enforce declared grants.

Filesystem adapters used for Flatpak install/persistence are swappable contracts: they must provide the needed permissions/links/xattrs/atomic rename/mmap/durability or fail closed. Do not silently bypass a selected virtual/SQLite-backed mount via the host filesystem. User `home`/`media` grants are a different contract from that deployment filesystem.

Required display lane: real **Xorg** or **Xwayland inside the native compositor session**. D1-only framebuffer and pure Wayland previews cannot close this gate. Probe the actual Electron display choice; do not rewrite this manifest to claim native Wayland.

Missing runtimes, unsupported namespaces/seccomp, or missing display must be recorded `unavailable` or `failed` — never a successful stub, never a host Linux or remote window.

Calculator C1/C2 remains mandatory and **does not** close Photon. Existing D1/D2 stages stay; this contract is the Photon row.

When a real run exists, store evidence under `tests/native-distro/photon-studio/<run-id>/` as listed in `manifest.json` (`evidence_when_run_exists`). That directory must not be created as a fake pass.

## Status vocabulary

`manifest.json` check rows today use only `not_run` and `blocked_prerequisites`. Future executable qualification may add `unavailable`, `failed`, or `passed` with native evidence. `passed` without the provenance bind in PHOTON-1 is invalid.
