# Photon Studio native desktop compatibility (PHOTON-1)

**Status:** mandatory production implementation/release gate and acceptance contract. Native desktop Flatpak is **not implemented**. Photon Studio has **not** been installed or run on a zig-kernel ISO. This document is not run evidence.
**Date:** 2026-09-13. **Publication rebaseline:** 2026-09-14 against selected accepted tree `6c8c8ca0611005e7776f437f381c55a866a67e3c`.
**Parent plans:** [desktop distro plan](desktop-distro.md) (Z9/KWP13 detail), [kernel-distro §16.4](../audits/kernel-distro.md#164-photon-studio-flatpak-mandatory-production-gate-photon-001-added-2026-09-13).
**Machine-readable contract:** [tests/native-distro/photon-studio/manifest.json](../tests/native-distro/photon-studio/manifest.json) and [README](../tests/native-distro/photon-studio/README.md).

**Current truth (as of selected head `6c8c8ca0611005e7776f437f381c55a866a67e3c`):** Native desktop Flatpak is **not implemented**. Photon Studio has **not** been installed or run on a zig-kernel ISO. No native CPL3 userspace, desktop session, calculator run, or Photon qualification exists. Bounded native x86_64 UEFI bootstrap is recorded in [native-bootstrap.md](native-bootstrap.md) (`linux_replacement_qualified` false; not CPL3, Linux ABI, Alpine, desktop, or Photon). Diagnostic sandbox API remains `execution:false` / `/readyz` 503 as recorded in [sandbox-api-implementation.md](sandbox-api-implementation.md). Native CR3 probe is a separate publication and is not in this checkout. Linux-hosted Alpine/Python/sandbox-API evidence closes nothing native and does not run this bundle. Calculator C1/C2 remains mandatory and **does not** close Photon.

Static header extraction below is **observed**, not an authenticated signature check and not a complete OSTree/ELF/runtime scan. The application was **not** executed. An inspection-container install stopped because `org.freedesktop.Platform/x86_64/25.08` was absent; that is **not** proof that Flatpak 1.14.10 is incompatible, and **not** proof that a static OSTree checkout inherently requires an installed runtime. Payload/wrapper/ELF/Electron versions and signatures remain unverified. Provisional staging commit is not a verified installed app commit.

## 0. Gate class

| Field | Binding |
| --- | --- |
| Gate id | **PHOTON-1** |
| Class | Required **production release blocker** for the native desktop distro (P2). Not an optional wishlist, not closed by P0/D1 preview, not closed by calculator C1/C2. |
| Existing stages | Preserve C1/C2 and D1/D2. Photon adds prerequisites and its own gate row; it does not replace them. |
| Implementation | Unmodified user-supplied Flatpak bundle on the **booted native ISO**, as an ordinary user, through real Flatpak/OSTree/bubblewrap, declared entrypoint, and declared permission policy. |
| Fail-closed | Unsupported required isolation, missing runtime/extension, missing X11 socket, missing DRI-or-labelled-software-GL, or missing PulseAudio-or-verified-PipeWire-Pulse **must** record `unavailable` or `failed`. Never stub a successful capability. |
| Forbidden substitutes | Host Linux windows, remote/forwarded windows, extracted ELF executed outside Flatpak, **adding** `--no-sandbox` or extra `--filesystem=host` as an acceptance shortcut, rewritten Wayland-only launch, musl-host “it might work,” host-fs bypass of a selected virtual/SQLite mount, or any pass recorded without native PID/address-space/input/compositor provenance. The upstream `electron-wrapper` implementation is **unknown**; do not assert it contains no such flag, and do not invent a proven Chromium-inner sandbox. Flatpak **outer** containment must enforce declared grants. |

## 1. Supplied artifact identity

Public identity is **basename + size + SHA-256**. Operators supply a local filesystem path to that file. Product docs and ISO trees **must not** embed the 282701144-byte bundle (282.7 MB decimal / 269.6 MiB) without a recorded license/distribution basis (none is claimed here). Filename version `0.1.5` is **not** signed provenance.

| Field | Value | Class |
| --- | --- | --- |
| Basename | `Photon-Studio-0.1.5-linux-x64.flatpak` | observed (operator-supplied name) |
| Size | `282701144` bytes | observed (header-evidence receipt) |
| SHA-256 | `49db545b57e9f6c01c063a7f90e774c446a20d10f95b2943263ae5154c077f6a` | observed (header-evidence receipt) |
| Magic | `flatpak\0` (`666c617470616b00`) | observed (raw header scan) |
| Header ref | `app/com.tenzen.photon/x86_64/stable` | observed |
| Architecture implied by ref/filename | `x86_64` | observed |
| ARM / Windows / macOS support | **not proven** by this bundle | derived from artifact scope |
| Source path | user-provided path to the named file | policy; absolute path is private inspection only |

The operator path is private inspection only and is not public product identity. Observation method: raw byte scan; no Flatpak runtime or application executed.

## 2. Header metadata (observed)

Extracted from the bundle header (448 metadata bytes at documented offsets). Not a `flatpak info` from an installed ref.

### 2.1 Application

| Key | Value |
| --- | --- |
| `name` | `com.tenzen.photon` |
| `runtime` | `org.freedesktop.Platform/x86_64/25.08` |
| `sdk` | `org.freedesktop.Sdk/x86_64/25.08` |
| `base` | `app/org.electronjs.Electron2.BaseApp/x86_64/25.08` |
| `command` | `electron-wrapper` |

### 2.2 Context / permissions (declared; honor, do not widen)

| Key | Value |
| --- | --- |
| `shared` | `network;ipc;` |
| `sockets` | `x11;pulseaudio;` |
| `devices` | `dri;` |
| `filesystems` | `home;/media;/run/media;` |

**Not present in this header:** Wayland socket, `--filesystem=host`, session/system bus names, portal allowlists, `--talk-name` / `--own-name` lists, `--no-sandbox`.

### 2.3 Debug extension (not a launch runtime)

| Key | Value |
| --- | --- |
| Extension | `com.tenzen.photon.Debug` |
| `directory` | `lib/debug` |
| `autodelete` | `true` |
| `no-autodownload` | `true` |
| `built-extensions` | `com.tenzen.photon.Debug;` |

Debug is metadata for an optional debug payload. `no-autodownload=true` plus `autodelete=true` means it is **not** an automatic extra install for launch.

### 2.4 Extra header tokens (observed, incomplete)

Raw header also contains GVariant-style extra keys after the INI:

| Token | Observed value | Meaning now |
| --- | --- | --- |
| `collection-id` | empty | no Flathub/collection pin from this header |
| `ostree.endianness` | `l` | little-endian OSTree payload indication |
| static-delta path token | `deltas/fz/JJaiONPJIln4LpIxoBDqDCvP89yzTDUlANKFN1CRU/0` | header path string only; **not** a pinned/authenticated OSTree commit |

Following bytes look like compressed payload (`xz` magic). That is **not** a completed unpack, commit pin, or ELF inventory.

## 3. Required distinctions (do not collapse)

1. **SDK / BaseApp metadata ≠ launch-runtime installs.** `org.freedesktop.Sdk/.../25.08` and `app/org.electronjs.Electron2.BaseApp/.../25.08` are build/base metadata. Do **not** automatically install them as extra runtimes. Launch needs the **resolved** Platform plus whatever runtime/GL/font/locale **extensions dependency resolution actually requires**. Pin those commits **after** resolution. **Do not invent commits.**
2. **A Flatpak bundle is an app payload**, not a complete Linux kernel, not a complete OS, and not all declared runtimes. Missing Platform/extensions → `unavailable`/`failed`, never a silent host fallback.
3. **Filename version is not signed provenance.** Local SHA-256 of the file is identity of **this blob**. GPG/OSTree signature, remote collection, and trust policy are separate and currently **unknown** (not authenticated).
4. **This blob is x86_64.** It does not prove ARM64, Windows, or macOS Photon support (Z10/other arches stay independently gated).
5. **BaseApp hints Electron; it does not pin Electron/Chromium.** Exact Electron/Chromium versions, `electron-wrapper` implementation, and Chromium sandbox method stay **unknown** until extraction or a written inspection receipt. Do not guess version numbers.
6. **Preserve the declared entrypoint and permission policy.** Command remains `electron-wrapper` (inspect the upstream wrapper; do not replace it). **Do not add** `--no-sandbox` or extra `--filesystem=host` as an acceptance shortcut. Do not execute an extracted binary as the acceptance shortcut. The wrapper’s internal flags are **unknown** until extraction; do not claim a proven Chromium-inner sandbox. Flatpak outer containment must actually enforce the declared grants.
7. **Host libc ≠ app runtime libc.** A musl native host/userland (P-musl) does **not** automatically run a glibc Freedesktop Platform Flatpak. Photon requires a **glibc-compatible Flatpak host profile** (P-glibc overlay or a separately gated compat profile). Mixing musl and glibc loaders in one root is still forbidden.
8. **`home` is granted.** Do **not** claim home isolation. Test denials on **selected protected host paths** that sit **outside** the explicitly authorized host mounts (`home`, `/media`, `/run/media`). Do **not** demand denial of every path outside those mounts: `/app`, `/usr`, and necessary virtual filesystems are valid app/runtime mounts. Host folder exposure still requires sandbox mount authorization, not an arbitrary host bypass.

## 4. Implementation chain (each item a fail-closed prerequisite)

Photon does not start at the `.desktop` file. Native kernel + distro must actually provide:

### 4.1 Kernel / UAPI (unmodified Flatpak / OSTree / bubblewrap / runtime / app)

- Native Linux x86_64 binary and UAPI compatibility, including a **dynamic glibc loader** path for unmodified Flatpak tools, OSTree, bubblewrap, the Freedesktop Platform, and the app.
- User, mount, PID, and IPC namespaces with **seccomp enforcement**. If a required namespace or seccomp is unsupported → fail closed (`unavailable`/`failed`), no fake capability stub.
- Process, thread, TLS, futex, signals, epoll, memfd, shared memory, Unix sockets, and FD passing.
- `/proc`, `/sys`, `/dev` and durable permission / xattr / hardlink / atomic rename / mmap behaviors **as required by the actual package and runtime**, verified against those requirements rather than a slogan.
- **Filesystem adapters are swappable contracts.** Photon/Flatpak **install and persistence** must declare and test the capabilities actually needed (permissions, links/xattrs, atomic rename, mmap/backing, durability). Do **not** silently bypass a selected virtual/SQLite-backed mount by using the host filesystem. An adapter qualifies only if it implements those semantics; otherwise explicit capability `unavailable`/`failed`, and **no Photon pass** on that profile. Keep **runtime-deployment** filesystem requirements distinct from ordinary **user-selected** file mounts (`home`, `/media`, `/run/media`) and their read/write grants.

### 4.2 Flatpak + OSTree product

Build the real deploy/ref/runtime-resolution/trust path:

- `flatpak install` from the **user-supplied** bundle (offline **only** when the full runtime/extension closure is preseeded; otherwise explicit network-or-unavailable, never a fake offline pass).
- Ref install: `app/com.tenzen.photon/x86_64/stable`.
- Runtime resolution for `org.freedesktop.Platform/x86_64/25.08` plus **actually required** GL/font/locale extensions; pin **resolved** commits in the run evidence. SDK/BaseApp not auto-installed.
- Trust/signature policy **separate** from “we hashed the local file.” Unsigned or untrusted remote fetches cannot be relabelled as this bundle’s SHA-256.
- Transaction, update, rollback, uninstall, reinstall; keep vs purge user-data semantics (proposed in §7.4).
- Offline dependency closure recorded (every blob digest) before claiming offline install.

### 4.3 Display / audio / device contract (from this header)

| Declared | Required native provision | Forbidden |
| --- | --- | --- |
| socket `x11` | Real **Xorg** or **Xwayland inside the native compositor session**. Required Photon launch lane. | Pure Wayland session, D1-only framebuffer preview, silently rewriting the manifest to “native Wayland,” host-forwarded X. |
| no Wayland socket | Probe **actual** Electron/toolkit display choice at launch. If it needs X11, keep X11. | Claiming Wayland compatibility from this header. |
| socket `pulseaudio` | PulseAudio socket, **or** a **verified** PipeWire-Pulse bridge that actually presents that socket. | Advertising audio without a socket; claiming PipeWire native protocol from this header. |
| device `dri` | Declare and test the **selected** lane: real DRM/DRI device+driver, **or** a clearly labelled **verified software-rendering** profile that does **not** claim hardware acceleration. The DRI **request** does not prove hardware acceleration, a particular Mesa, or a codec. | Hardware-GL wording on a software path; missing DRI with a silent CPU fallback that still says “dri supported.” |
| `shared=network` | Native network as the app actually uses it, with evidence. | Invented cloud features. |
| `shared=ipc` | IPC namespace / shm as Flatpak uses it. | Stub. |
| filesystems `home;/media;/run/media` | Mount those; deny **selected protected host paths** outside those authorized host mounts; record writes the app actually performs. `/app`, `/usr`, and necessary VFS mounts are valid runtime paths, not automatic denials. | “Sandboxed from home” claims; `--filesystem=host`; requiring denial of every non-home path. |

Session and system D-Bus, portals, fonts, IME, clipboard, drag-and-drop, scaling, `.desktop`/menu integration are **explicit capabilities** with their own tests. **Do not invent** unobserved D-Bus service allowlists or app features. If a portal is required in practice, record it from observation, then pin and test it.

### 4.4 Relation to D1 / D2 / C1 / C2

| Stage | Photon relationship |
| --- | --- |
| D1 custom framebuffer + C1 `zk-calc-d1` | Remains first GUI slice. **Cannot** close PHOTON-1 (no X11 socket, no Flatpak). |
| D2 Wayland/Hyprland + C2 `zk-calculator` | Remains mandatory later desktop. **Cannot** close PHOTON-1 unless an X11 socket (Xwayland or Xorg) is actually provided and Photon is launched through it. |
| Direct Xorg (already a required P2 profile) | Eligible Photon X11 lane if that server is the one the app’s `DISPLAY` uses, with native provenance. |
| Xwayland (already a separately verified bridge) | Eligible Photon X11 lane **only** after that bridge’s own gate, and only inside the native session. |
| Wine / Cocoa / ARM64 / `omacalc` | Unchanged required-later rows. Photon does not close them; they do not close Photon. |

## 5. PHOTON-1 runtime acceptance

All of the following on **one** pinned native ISO run. Status today: **not run** / **blocked on prerequisites**.

### 5.1 Provenance bind (before any UI claim)

Bind into the run evidence:

- Exact native ISO identity (bytes + SHA-256) and boot firmware profile.
- Guest kernel, rootfs, and **Flatpak/OSTree/bubblewrap** binary identities.
- User-supplied bundle basename, size, SHA-256 matching §1.
- Installed app ref + **app commit** (from OSTree, once resolved — currently unknown).
- Resolved runtime and extension **digests/commits** (currently unknown; do not invent).
- Signature/trust verification **result** (pass/fail/unavailable), distinct from local file hash.

Boot that ISO so a native graphical session exists. Host Linux is not the guest.

### 5.2 Install and metadata

- `flatpak install` of the supplied bundle. Offline only with a **preseeded full runtime/extension closure**; otherwise record network use or `unavailable`.
- `flatpak info com.tenzen.photon` and permissions **match** this header (name, runtime ref, command `electron-wrapper`, shared/sockets/devices/filesystems). Extra permissions fail the row. Missing required declared permissions fail the row.
- SDK/BaseApp not silently installed “to make it work” unless resolution truly requires a named ref — and then pin it.

### 5.3 Launch

- Ordinary (non-root) user.
- Desktop menu entry **and** `flatpak run com.tenzen.photon`.
- Entrypoint remains the Flatpak command (`electron-wrapper` via Flatpak). No extracted-binary shortcut. **Do not add** `--no-sandbox` or extra `--filesystem=host`. Do not assert unknown wrapper internals.
- Native PID, parent chain, address spaces (compositor / Xorg-or-Xwayland / bwrap / runtime / app), input path, and compositor provenance recorded. Direct model fakes and host windows fail the run.

### 5.4 Interactive display and input

- Real rendered main window (guest frames/video, not a host screenshot of a different process).
- Responsive keyboard, mouse, resize, focus.
- Second-app clipboard and file selection using native input (second app = a named native desktop app from the [desktop matrix](desktop-distro.md), e.g. `foot` / `nautilus`, once those exist).

### 5.5 Core workflow (do not invent)

Identify **actual** app workflows **after** inspection and UI observation. **Do not invent** a supported project format, document type, or cloud backend.

Until that observation exists, the core-workflow identity is **unknown**. PHOTON-1 still requires, once the UI is visible:

- Exercise **at least one observed** core workflow.
- Real authorized `home` and `/media` or `/run/media` file **read and write**, then reopen, then reboot persistence of those files (checksums).
- Declared networking, audio, and graphics **where the app exposes them** — test the exposed surface; do not invent buttons.
- Permission **denials** on **selected protected host paths** outside explicitly authorized host mounts. Do **not** require denial of `/app`, `/usr`, or necessary virtual filesystems. Withdrawing an ungranted device, host directory, socket, or network capability must be a **contained, diagnosable denial or graceful feature degradation**. It need **not** force whole-application exit. Privilege escalation on denial is FAIL.
- Child-process cleanup on close (Electron-class helpers must not leak).

### 5.6 Quantitative gates (proposed vs measured)

These are **proposed** thresholds for the P1-class QEMU baseline in [desktop-distro §7.1](desktop-distro.md#71-quantitative-gates-adopt-parent-111-minima-plus-gui-bounds--all-proposed-thresholds-not-measured-results) unless a Photon-specific RBM amends them. **Measured values do not exist.**

| Check | Proposed | Measured |
| --- | --- | --- |
| Launch to visible main window | ≤ 15 s or FAIL | not run |
| Input-to-visible-response (UI, not a fake IPC) | ≤ 1 s median on baseline | not run |
| Open/close/resize/focus/move cycles | 50×; 0 leaked PIDs/FDs; ΔRSS ≤ 1 MiB post-cycle | not run |
| Relaunch after clean close | 10× consecutive; same provenance rules | not run |
| Soak | adopt parent [§11.1](../audits/kernel-distro.md#111-proposed-quantitative-release-defaults) 24 h logged-in graphical session **with Photon launched at least once per hour** on the declared display/audio/DRI profile, or a recorded Photon-specific RBM amendment | not run |
| Skip of a required row | FAIL | — |

Calibrate through RBM review; never report a resource gate as passed without numbers.

### 5.7 Update / rollback / remove / reinstall (proposed semantics)

Define and test; do not claim observed Photon settings paths until the app is seen:

| Operation | Proposed expected |
| --- | --- |
| Update success | New app commit; user files in authorized mounts kept |
| Update failure / interrupted transaction | Previous app commit remains launchable; no half-ref treated as success |
| Rollback | Restored prior app commit launches |
| `uninstall` without data delete | Ref absent; **keep** app-id data (`~/.var/app/com.tenzen.photon` if that is what Flatpak used) |
| `uninstall --delete-data` (purge) | Ref absent; Flatpak app-id data **purged** |
| Reinstall after keep | App present; kept data still there |
| Writes under granted `home` **outside** Flatpak app-id dirs | May persist after purge because **home is granted**; record actual paths; do **not** call that “home isolation” |
| Offline reinstall | Only with preseeded closure |

Signed/trusted **source policy** (which remotes/keys may update Photon) is a **separate** gate from “this local bundle hashed.” A later Flathub or vendor remote is not this file.

## 6. Evidence bundle (required when a run exists)

Store under `tests/native-distro/photon-studio/<run-id>/` when a native run is actually executed (directory does not exist as a pass record today):

- Installer and `flatpak` logs.
- App + runtime metadata, refs, commits, extension digests.
- Signature verification result (and method).
- Source manifest (this contract + ISO/kernel/rootfs/Flatpak binary hashes).
- Guest kernel identity and process tree (PID/exe/hash, including bwrap and helpers).
- Guest HID event stream.
- Frames/video of the real window + hashes.
- Observed workflow file checksums (authorized home/media).
- Errors, exits, resource metrics (RSS, FD, PID counts).
- `results.json` asserting each check id; required-row skip = FAIL.
- Explicit `unavailable`/`failed` if runtimes, namespaces, seccomp, or display are missing.

**This repository currently contains no such run directory and no pass record.**

## 7. Unknowns (explicit)

Do **not** fill these with guesses:

- Authenticated OSTree **app commit**, Platform commit, GL/locale/font extension commits. Inspection staging commit `7f32496a238d3c92259f82e9231a010ea0c2bcff3dcb34c352500d2853750915` is **provisional import output only**, not a verified installed app commit.
- GPG/OSTree signature validity and `collection-id` remote.
- Complete file tree, ELF interpreter list, and whether the payload is a static delta only. Advisor payload inspection status: **unverified** (no checkout).
- Exact Electron, Chromium, `electron-wrapper`, and Chromium-sandbox bits (user/namespace/seccomp/SUID/none).
- Whether the running app talks Wayland **anyway** (header does not request it; probe at runtime).
- D-Bus names, portals, MIME types, and `.desktop` Name/Icon (not in this header).
- Actual user-visible workflows and file formats.
- Settings path(s) besides whatever inspection later shows.
- Hardware vs software GL need; PipeWire vs PulseAudio native protocol.
- License allowing redistribution of the 282701144-byte blob into git or the ISO.

Private OSTree staging from static inspection is **not** a pinned commit and is not published here. Do not invent commits from it.

## 8. Traceability

| Claim | Where |
| --- | --- |
| Mandatory production blocker PHOTON-1 | this doc; [desktop-distro](desktop-distro.md) §3.2/§5/§7; [kernel-distro §16.4](../audits/kernel-distro.md#164-photon-studio-flatpak-mandatory-production-gate-photon-001-added-2026-09-13); README native-delivery paragraph |
| Machine-readable checks | [manifest.json](../tests/native-distro/photon-studio/manifest.json) |
| Contract README | [tests/native-distro/photon-studio/README.md](../tests/native-distro/photon-studio/README.md) |
| Header observation | this document §1–§2 (raw header scan; not a run) |
| Static bundle limits | this document §7 (app not executed; payload unverified; private receipts not published) |
| Calculator still mandatory | [desktop-distro §6](desktop-distro.md#6-calculator-evidence-contract-d4-repaired) |
| C1/C2/D1/D2 preserved | [desktop-distro §0/§3/§7](desktop-distro.md) |
| Alpine/Python/sandbox unchanged | those owners; Photon does not edit them |

Production native desktop **cannot** be declared complete while PHOTON-1 is `not_run` or `blocked_prerequisites`.
