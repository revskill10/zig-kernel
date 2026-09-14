# Native Zig-kernel desktop distro ISO plan

**Status:** detailed implementation/acceptance plan. Not built, not booted, no ISO exists, no calculator run proven. Native desktop Flatpak is **not implemented**; Photon Studio has **not** been installed or run on this distro.
**Date:** 2026-09-13. **Publication rebaseline:** 2026-09-14 against selected accepted tree `6c8c8ca0611005e7776f437f381c55a866a67e3c`.
**Photon:** mandatory PHOTON-1 production gate; see [photon-studio.md](photon-studio.md) and [acceptance manifest](../tests/native-distro/photon-studio/manifest.json). Plan/contract only.
**Parent audit:** [kernel-distro plan](../audits/kernel-distro.md) — Z9/KWP13 mandatory, gates Z1–Z11/V1–V5/LNX0–LNX3/R1 plus PHOTON-1. This doc details Z9/KWP13 including Photon.

**Current truth (as of selected head `6c8c8ca0611005e7776f437f381c55a866a67e3c`):** no native CPL3 userspace, no desktop, no ISO, no calculator execution, **no Photon/Flatpak run**. Bounded native x86_64 UEFI bootstrap is recorded in [native-bootstrap.md](native-bootstrap.md): PE32+ loader, ELF64 payload, FAT16 ESP, 108-byte `INITRMF1` smoke; hosted native contracts and qualifier host fixtures as documented there; `linux_replacement_qualified` is false. Diagnostic sandbox API remains `execution:false` / `/readyz` 503 as recorded in [sandbox-api-implementation.md](sandbox-api-implementation.md). Native CR3 probe is a separate publication and is not in this checkout. Linux-hosted Alpine/Python/OCI evidence closes nothing native. Photon facts in this plan are static header observation only (application not executed; payload/ELF unverified).

## 0. Baseline decisions (D1 repaired)

| Decision | Selected baseline | Rationale / gate |
| --- | --- | --- |
| First arch | x86_64 QEMU/KVM (q35, OVMF, 8 GiB P1; 256 MiB TCG smoke per evidence run); ARM64 separately gated (Z10) | Vinix amd64 desktop recipe (`run-desktop-amd64.sh`: q35, `-vga std`, 4 vCPU, KVM/TCG) is the closest local comparator |
| Boot chain (baseline, retained) | Native Zig EFI loader + BootInfo contract, systemd-boot chain (parent §5.2, §6 Z1) | The isolated native code implements its own EFI loader and BootInfo handoff, not a Limine kernel-entry implementation; retained EFI tests stay green before any migration |
| Limine (comparator / gated adapter only) | Vinix `build-amd64-iso.sh` Limine recipe is a comparator; a Limine-boot adapter would be a separately gated profile with a named handoff adapter, retained EFI tests, and extra acceptance — it does **not** supersede the EFI baseline | Reconciles parent Z1/systemd-boot with the Vinix ISO pattern instead of silently contradicting it |
| Initial root format (planned) | cpio/newc read-only subset carrying exactly `/init` + manifest (KWP3a) | Current 108-byte smoke envelope is **not** a filesystem: 64-byte header (magic `INITRMF1`, version 1, `HEADER_SIZE` 64, payload size + additive-u64 checksum, per this checkout `src/native/initramfs.zig`) + 44-byte fixed payload (`tools/mkinitramfs.zig`: `zk-native initramfs v1 (KWP2 smoke payload)`). Transition acceptance: validate file bounds/names/duplicates/types + ELF bytes before handoff; pin image digest; absent/corrupt `/init` fails explicitly |
| First compositor | Custom framebuffer compositor, software canvas, per-process apps over versioned pipe IPC (Vinix VAPP pattern, own version, not VAPP bytes) | Smallest real GUI slice; Wayland/Hyprland is the later mandatory Omarchy profile, not the first milestone |
| Omarchy profile | Wayland session primary: Hyprland via uwsm (`omarchy.desktop`), Quickshell, portals; Xwayland only as separately verified bridge | Grounded in local Omarchy checkout; exact package pins recorded at build time, never "latest" |
| ABI profiles (never mixed) | P-boot: static initramfs tools; P-musl: Alpine/musl/apk userland (Vinix parity); P-glibc: Arch/glibc/pacman userland (Omarchy parity) | Vinix amd64 = Alpine/musl static (`build-desktop-amd64.sh:103-104`); Omarchy = Arch/glibc. Separate rootfs/loader/repo per profile |
| Calculator slice C1 | Native framebuffer calculator `zk-calc-d1`, own process, own PID, immediate-execution semantics (§6), no external toolkit | Mirrors Vinix native ui2 Calculator shape (`calculator_app.v`); smallest end-to-end |
| Calculator slice C2 (mandatory later) | **Proposed own-app `zk-calculator`, GTK4, Wayland** on Hyprland session; `omacalc` (Arch package, `omarchy-base.packages:95`) retained as required later behavior-compat target (gate V-parity-omacalc) | Explicit proposed design; C1 success never closes C2 or compat gates |
| Wine calculator | Repository Win32 sample (`tests/wine/calculator.c` — not Microsoft's calculator); div-zero `= 0.0` frozen semantics; required later parity rows per §3.2 (amd64 direct, ARM64 translated) | Never conflated with native calculator artifact |
| Photon Studio (PHOTON-1) | Unmodified user-supplied `Photon-Studio-0.1.5-linux-x64.flatpak` (`com.tenzen.photon`, x86_64) via real Flatpak+OSTree+bubblewrap on the native ISO; **production release blocker** | Header-observed X11+PulseAudio+DRI+home/media; not implemented; calculator/D1/D2 success never closes it |

## 1. Products / media contract

- **Artifacts:** versioned signed reproducible hybrid live/install ISO (`zk-desktop-<arch>-<version>.iso`), plus SHA-256, SBOM (source + binary closures with digests), provenance (RBM bytes), recovery image. Reproducibility: two builds from same RBM → identical ISO bytes; verifier script compares.
- **Boot:** UEFI only at first (OVMF profile pinned); hybrid El Torito layout per Vinix `build-amd64-iso.sh` pattern (kernel + initramfs + bootloader + UEFI image, all checksummed; Zig baseline uses its EFI loader/systemd-boot chain per §0, Limine adapter only if separately gated). Boot menu: Live / Install / Rescue / Memcheck-serial. USB dd + optical + `--cdrom` all tested; Secure Boot: self-signed key enrolled by installer with owner-recorded KEK/db; offline install default (no network required).
- **Install:** destructive-op consent, GPT + LUKS2 + Btrfs (`root`/`home`/`snapshots` subvolumes, snapshot rollback = Omarchy-semantic requirement; a functional alternative gets a different name + its own recovery rules per §Z9), initramfs with LUKS unlock + key-recovery printout, first-boot user creation, failure → rescue shell, never reports success before target boots standalone (ISO removed).
- **Release profiles (D5):** **P0 preview** — nonproduction GUI preview (C1a only: boot + interactive calculator, no persistence/install claim); **P1 QEMU candidate** — full C1 (C1a+C1b: + persistence, installer-to-disk, rollback/recovery on QEMU); **P2 production** — full gates + hardware. GPU-accelerated, real-laptop power/hotplug, Wi-Fi/BT/printing are unsupported in P0/P1 and separately mandatory P2 profiles with own RBMs — never "unsupported-with-rationale" retirements of the final goal.
- **Finite hardware profiles:** P0/P1 = QEMU q35, OVMF (pinned), std VGA → virtio-gpu software path, 4 vCPU / 8 GiB (KVM; TCG fallback noted, cf. `run-desktop-amd64.sh`); P2 adds per-class RBM machine/firmware/driver tuples only after driver/firmware/license/security acceptance.
- **Owner paths:** `images/native-desktop/` (ISO assembly), `distro/keys/` (signing), `scripts/release-native/` (reproducibility verifier), `tests/native-distro/` (install/persist/rollback corpus). Release/spec lead owns RBM + evidence review (R1).

## 2. Kernel-to-desktop chain (ordered, each a gate dependency)

Z1 boot/traps → Z2 CPL3/one process (KWP3a `/init` probe first: cpio/newc read-only root per §0, static ET_EXEC `/init`, Linux-amd64 6-arg frame, console-write + exit only, ENOSYS rest) → Z3 MM/SMP → Z4 durable VFS/block → Z5 UAPI tiers → Z6 devices/net → Z7 security → Z9 desktop. Desktop needs, in order:

1. process/ELF (ET_EXEC → ET_DYN + PT_INTERP for musl loader), guarded stacks, auxv/TLS, signals, exit/wait/reap;
2. FD/pipes (native IPC rides on two private pipes), unix sockets, shm (file-backed mmap/mprotect for `wl_shm` + VSF1-style mappings), futex, poll/epoll, timers, PTYs (terminal app), evdev + pointer/fb equivalents (geometry ioctl + mmap, Vinix `framebuffer.v`/`input.v` dimensions: fbdev ioctls `0x4600`/`0x4602`, 32-byte pointer packet), DRM/KMS (virtio-gpu, modeset, GEM/dma-buf/fences) for the Wayland stage, udev-equivalent discovery, ALSA, netlink, procfs/sysfs/cgroups (systemd/logind require them);
3. software renderer first (explicit milestone, QEMU std/VGA + virtio-gpu software path); accelerated GPU / real-laptop power / hotplug are separately mandatory P2 profiles with own RBMs.
- **Rule:** no display window without native process provenance — every pixel owner has a guest PID in the run manifest; host-forwarded windows are fraud, not evidence.
- **Photon/Flatpak additions (PHOTON-1, fail-closed):** native x86_64 UAPI plus a **dynamic glibc loader** for unmodified Flatpak/OSTree/bubblewrap/Freedesktop Platform/app (a musl P-musl host does **not** automatically run this glibc Flatpak; a glibc-compat host profile is required and must not mix loaders in one root); user/mount/PID/IPC namespaces and **seccomp enforcement**; process/thread/TLS/futex/signals/epoll/memfd/shared memory/Unix sockets/FD passing; `/proc`,`/sys`,`/dev` and durable permissions/xattrs/hardlink/atomic rename/mmap as required by the actual runtime. Unsupported required isolation → explicit `unavailable`/`failed`, never a successful stub. Details: [photon-studio.md](photon-studio.md).

## 3. Desktop protocol decisions (D2 repaired)

**Stage D1 (first): custom framebuffer protocol, versioned (own magic, not VAPP bytes).** Compositor alone owns fb/pointer/keyboard; apps are separate processes with two private pipes. Commands: build/handle/key/pointer/poll/close; resize re-layout; close asks + reaps. Source/license provenance for any Vinix-derived design detail is ordinary release inventory in the RBM/SBOM; no Vinix source is copied into the Zig tree without license review. Parity means **ported app behavior** through this IPC, not unmodified Vinix-protocol/client compatibility.

### 3.1 Interface inventory by boundary (provider → client, pin location, conformance test)

**A. Wayland wire interfaces (D2; compositor = pinned Hyprland, uwsm-managed):**

| Interface | Function | Pin location | Test |
| --- | --- | --- | --- |
| `wl_compositor` + `wl_shm` | surfaces, software shared buffers | protocol XML versions in RBM | registry negotiation; shm buffer attach/show/teardown |
| `xdg_wm_base` | toplevel lifecycle (map/configure/close) | same | open/move/resize/close corpus, configure ack |
| `wl_seat` + `wl_keyboard`/`wl_pointer`/`wl_touch` | input focus | same | focus routing, key/pointer/touch events to right client |
| xkb layout (userspace library `xkbcommon`, not a wire global) + IME as required feature (§3.1A note) | layout/IME | package pins | layout switch + IME commit path once verified |
| output/scale (`wl_output` + registry `zxdg_output_manager_v1` + registry `wp_fractional_scale_manager_v1` with per-surface child `wp_fractional_scale_v1`, as selected) | HiDPI/hotplug | same | mode/scale change, hotplug re-layout |
| clipboard/drag-drop (`wl_data_device_manager` + registry `zwp_primary_selection_device_manager_v1` as selected) | copy/paste | same | §6 clipboard vector |
| decoration negotiation (`zxdg_decoration_manager_v1`) | server/client decoration negotiation (both sides, not client-only) | same | negotiate each mode, fallback verified |
| app-launch/session-lock (`xdg_activation_v1`, `ext_session_lock_v1` as selected) | launch, lock | same | launch + lock/unlock cycle |

Only the extensions the named §5 apps need; each optional row names its selecting app/profile or stays out. Registry globals vs child interfaces vs userspace libraries are distinct columns above: `xkbcommon` is a client-side library, text input binds registry `zwp_text_input_manager_v3` (child `zwp_text_input_v3`). IME support (fcitx5 + selected toolkit input-method tuple bound to the pinned compositor) is a required feature with an explicit verification gate until proven; no unverified IME interface is claimed. Selected protocol XML/provider source and the version-manifest location are recorded in the RBM per row.

**B. X11/Xwayland (separate bridge profile, own process/PID, security/integration tests):** Xwayland version pin + required X extensions (e.g. XTEST/XDamage-class input/damage behavior as selected) with per-extension test; never "X11 supported" from one app. Vinix direct-X11 reference: xorg-server **21.1.16** + xf86-video-fbdev per `build-x11-aarch64.sh:33` (corrected from 21.1.6 typo). **PHOTON-1 launch lane:** the supplied Photon header requests socket `x11` and does **not** request Wayland; required provision is real Xorg **or** Xwayland **inside the native compositor session**. Pure Wayland or D1-only preview cannot close Photon. Do not silently rewrite the Photon manifest to claim native Wayland; probe the actual Electron display choice at run time.

**C. D-Bus / portal service APIs (not Wayland globals — category fix):** session+system bus, selected `org.freedesktop.portal.*` interfaces (Screenshot, ScreenCast, FileChooser, OpenURI as selected) with provider (`xdg-desktop-portal-hyprland` + `-gtk` per `omarchy-base.packages:143-144`) and per-interface test; Capture/screencast links to the required PipeWire path where selected.

**D. Native compositor IPC (D1):** §3 header contract — pin pixel format (XRGB8888 first), stride, ioctl numbers, 32-byte pointer packet layout, keyboard/termios behavior, poll timing, render ownership, PTY lifecycle; fuzz/malformed-client recovery test.

**E. Kernel device/UAPI deps:** §2 item 2 list; each needs readiness/failure/disable behavior (L3 pattern).

### 3.2 Desktop-path profile decisions (full coverage, no unexplained exclusions)

| Path | Decision | Mechanism + gate kind | Kernel/device contract |
| --- | --- | --- | --- |
| Native framebuffer + own IPC | **Required** (D1/C1) | own product, gate Z9-slice | fb/pointer/keyboard/PTY per §2 |
| Direct Xorg | **Required** P2 profile (own server/driver/WM/input-bridge pins at RBM); **eligible PHOTON-1 X11 lane** | ported stack, gate Z9 | KMS/fbdev + evdev + session |
| Embedded Xvfb bridge (Firefox/GIMP/Wine-class) | **Required** P2 profile (private display, socket ownership, focus isolation, repaint sync, cleanup). **Not** a Photon acceptance shortcut (no hostless “Xvfb equals Photon window” claim) | ported stack, gate Z9 | shm + process/input bridge |
| Wayland/Hyprland | **Required** (D2/C2, §3.1A). **Does not** close PHOTON-1 by itself (Photon header has no Wayland socket) | ported stack, gate Z9 | DRM/KMS, GEM/dma-buf/fences, evdev/seat, udev |
| Xwayland | Separately verified bridge, not inherited; **eligible PHOTON-1 X11 lane** only after its own gate and only inside the native session | ported bridge, own gate | own process + X-extension tests |
| Flatpak + OSTree + bubblewrap (Photon host) | **Required** production path (PHOTON-1). Real deploy/ref/runtime-resolution/trust/transaction/update/rollback/uninstall/offline closure. Honor declared permissions; **do not add** `--no-sandbox` or extra `--filesystem=host` as an acceptance shortcut; no extracted-ELF shortcut. Wrapper internals unknown — do not invent a proven Chromium-inner sandbox | unmodified-binary Flatpak app on glibc-compat host; gate PHOTON-1 | namespaces/seccomp, glibc PT_INTERP, unix/fd-passing/memfd/shm, xattrs/hardlink/atomic rename, `/proc` `/sys` `/dev`; **swappable FS adapters** must implement those semantics or fail closed (no silent host-fs bypass); DRI lane declared (request ≠ hardware accel); PulseAudio or verified PipeWire-Pulse |
| Wine amd64 (direct Win64) | **Required later parity** (after C2; arch-gated, not cancelled) | unchanged-binary compat target; gate V-parity-Wine-amd64 | musl runtime + Xvfb bridge |
| Wine ARM64 (guest-user translation) | **Required later parity** (after C2; arch-gated, not cancelled) | translated-binary compat target (guest QEMU-user + musl root, separate from host QEMU running the guest); gate V-parity-Wine-arm64 | same + translation layer |
| Cocoa/Mach-O apps | **Required later parity** (after C2; arch-gated, not cancelled) | ported-behavior target (own compat path, same app behavior); gate V-parity-Cocoa | compat path deps at RBM |

**Services (real dependencies, all pinned at RBM):** systemd, D-Bus, logind, polkit, PAM, PipeWire+ALSA, NetworkManager, portals, fcitx5 (IME: `fcitx5-gtk`/`fcitx5-qt` in manifest), fonts/locale/timezone, notification, accessibility. **Photon:** PulseAudio socket **or** verified PipeWire-Pulse presenting that socket; session/system D-Bus and portals only as **observed-and-pinned** capabilities (do not invent D-Bus allowlists from an empty header); fonts/IME/clipboard/DnD/scaling/menu integration are explicit tests.

## 4. Packages (three profiles, never mixed)

| Profile | Loader/libc | Manager | Source of bytes |
| --- | --- | --- | --- |
| P-boot | static | none (initramfs) | Zig-built static tools |
| P-musl (Vinix parity) | musl `ld-musl-*.so.1` | apk via `vinix-pkg`-equivalent frontend (Vinix tracks Alpine 3.21, `vinix-pkg:33`) | Pinned Alpine minirootfs (record version+SHA at build; Vinix amd64 used 3.21.7) |
| P-glibc (Omarchy parity) | glibc loader tuple | pacman | Pinned Arch snapshot + keyring; manifest seeded from `omarchy-base.packages` content (pins recorded, not "latest") |

Rules: distinct boot/rootfs/ABI per profile; signed repos; reproducible cross-build ports; solver transactions with rollback; conflict/removal policy; offline cache; upgrade-failure handling; versioned app SDK/toolchain; `.desktop`/icons/MIME/associations; sandbox policy for GUI apps; source-ports vs unmodified-binary-compat explicitly labelled (unmodified musl loader + BusyBox + apk corpus must run on booted Zig kernel for P-musl; host-container runs never count).

**Photon host overlay (not a fourth mixed ABI):** PHOTON-1 runs on **P-glibc** (or a separately gated glibc-compat profile) with real `flatpak` + `ostree` + `bubblewrap` packages pinned at RBM. App runtime libc is the Freedesktop Platform (glibc), **separate** from host libc. P-musl does **not** close Photon. SDK (`org.freedesktop.Sdk/x86_64/25.08`) and BaseApp (`app/org.electronjs.Electron2.BaseApp/x86_64/25.08`) metadata are **not** automatic extra launch-runtime installs. Pin Platform + actually resolved GL/font/locale extension **commits after dependency resolution**; never invent commits. The bundle is app payload, not a kernel and not the full runtime closure. Do not copy the 282701144-byte blob (282.7 MB / 269.6 MiB) into the repo or ISO without a recorded license/distribution basis. Filesystem adapters used for Flatpak install/persistence are swappable contracts: they must implement required permissions/links/xattrs/atomic rename/mmap/durability or fail closed; do not silently use the host filesystem to bypass a selected virtual/SQLite mount. User-selected `home`/`/media`/`/run/media` grants stay distinct from that deployment filesystem.

## 5. Named app + normal-computer matrix (D3 repaired)

Exact versions/digests freeze at RBM assembly; software identity, toolkit/protocol, owner, and test are concrete now. Toolkits marked `verify at RBM` were not assumed from package names.

| App | Package/exe (profile) | Toolkit / protocol / deps | Owner path | Pin-manifest location | Observable test |
| --- | --- | --- | --- | --- | --- |
| Terminal | `foot` (P-glibc; `omarchy-base.packages:42`, default in `omarchy-menu.jsonc:158`) | Wayland client, PTY + shell | `native-desktop/` + `tests/native-distro/` | RBM package snapshot | PTY shell, alt-screen vim-class edit, resize |
| File manager | `nautilus` (P-glibc; `:85`) | Wayland/GTK (verify at RBM), `getdents`/`stat` | same | same | browse real fs, rename, persistence |
| Browser | `chromium` (P-glibc; `:16`, default in menu `:149`) | Wayland, own engine + update cadence declared at RBM; media/security strategy explicit | same | same | launch, page render, update/rollback |
| **Calculator C2** | **proposed own-app `zk-calculator` (P-glibc, GTK4, Wayland)** | GTK4 + §3.1A protocols | `native-desktop/calc/` | RBM source+lib pins | §6 C2 vectors |
| Calculator reference compat | `omacalc` (P-glibc Arch package, `:95`; toolkit unverified locally) | **required later parity**: ported-behavior target (same app behavior via own path) or unchanged-binary target — chosen and labelled at RBM, gate V-parity-omacalc; never closed by `zk-calculator` alone | `native-desktop/omacalc-compat/` | Arch snapshot + compat pins | same V1–V8 observables on the omacalc path |
| Editor | `nvim` + `omarchy-nvim` (P-glibc; `omarchy-base.packages:92,98`), running in `foot` | terminal app (no separate GUI toolkit; PTY + shell) | same | same | open/edit/save real file, clipboard roundtrip source/sink per §6.2 |
| Wine/Cocoa/translated-arch compat | per §3.2 required-later rows | bridges/translation, port-vs-binary labelled per row | `native-desktop/compat/` | Vinix manifest + compat pins | comparator runs only until their gates; own-clone success never closes them |
| Settings/panels | own apps (network/audio/display) | D1 then Wayland | same | same | preference change takes effect + persists |
| Package mgr / installer / updater / recovery | apk-frontend (P-musl) / pacman + installer (P-glibc) | §4 transactions | `distro/installer/` | same | §6 package lifecycle + S7/S11 corpus |
| Calculator C1 | `zk-calc-d1` (P-boot/P-musl, no external toolkit) | D1 IPC | `native-desktop/calc-d1/` | RBM source pins | §6 C1 vectors |
| Session/login/lock/logout | uwsm + Hyprland + lock (P-glibc) | `ext_session_lock_v1` as selected | same | same | login/lock/logout cycle |
| **Photon Studio PHOTON-1** | user-supplied `Photon-Studio-0.1.5-linux-x64.flatpak`; app-id `com.tenzen.photon`; command `electron-wrapper`; P-glibc/compat host + Freedesktop Platform 25.08 (commits **unknown until resolved**) | Flatpak/OSTree/bwrap; **X11** socket (Xorg or Xwayland in native session); PulseAudio or verified PipeWire-Pulse; DRI or labelled software-GL; filesystems `home;/media;/run/media`; network+ipc. Electron/Chromium versions **unknown**. Do not invent project formats | `tests/native-distro/photon-studio/` | [photon-studio.md](photon-studio.md) + [manifest.json](../tests/native-distro/photon-studio/manifest.json); RBM pins after resolution | PHOTON-1 vectors in that contract; status `not_run` / `blocked_prerequisites` until a native ISO run |

Blocking until implemented: multitasking + 2+ windows, clipboard, home persistence, accessibility/i18n/HiDPI, input hotplug, sleep/resume/power, browser/media/security cadence + resource/perf gates (§7), **and PHOTON-1**. Interim "unsupported" labels milestones only, never retire required final features. C1/C2 success never closes Photon.

## 6. Calculator evidence contract (D4 repaired)

Semantics (frozen, own-app design): **immediate-execution** (single pending operator, left-associative chaining — same model class as the Wine sample); native div-zero → sticky **`Error`**, locked until Clear (explicitly differs from the Wine sample's `0.0`, which is retained unchanged as comparator). Reset precondition: press Clear, expect `0`, before every vector row.

**Provenance preconditions (before any vector):** independently inspect the candidate ISO's embedded payload (kernel/rootfs/compositor/calculator bytes + SHA match `manifest.json`); boot that pinned image via the pinned firmware profile; start the native session so the compositor runs; show the calculator absent; launch it through the real guest menu/shortcut/terminal; record the guest PID, parent chain, executable identity, and distinct compositor/app address spaces. Inject every input through virtual HID hardware (or real hardware) → native input driver → compositor → app. Direct model invocation, forged IPC answers, precomputed result images, and host windows are forbidden and fail the run. Raw frames, event log, and result assertions stay tied to the same run hashes.

### 6.1 Input/result vector table (each row: reset → input events → expected display)

| # | Input (pointer-click P / keyboard K) | Expected | Covers |
| --- | --- | --- | --- |
| V1 | P `1`,`2`,`+`,`3`,`0`,`=` | `42` | pointer entry, addition |
| V2 | K `7`,`*`,`8`,`=` | `56` | keyboard entry, multiplication |
| V3 | P `2`,`.`,`5`,`+`,`0`,`.`,`7`,`5`,`=` | `3.25` | decimals |
| V4 | P `9`,`-`,`1`,`4`,`=` | `-5` | subtraction → negative |
| V5 | K `0`,`-`,`3`,`*`,`2`,`=` | `-6` | negative operand, chaining |
| V6 | P `2`,`+`,`3`,`*`,`4`,`=` | `20` (immediate-execution documented; precedence-aware would give `14`) | evaluation-model disclosure |
| V7 | P `5`,`/`,`0`,`=` → display `Error`; `+`,`1`,`=` still `Error`; `C` → `0`; `7` → `7` | sticky error + Clear recovery | div-zero, recovery |
| V8 | type exactly 64 digits (accepted, raw entry length bound = 64), then a 65th digit | 65th input ignored with sticky `Error` until Clear; `C` → `0`; re-entry clean | entry-length bound |

Capture per vector: before/input/after frames + timestamped event log; screenshots show results; `results.json` asserts each row machine-readably; raw screendump/video + hashes retained.

### 6.2 Window/clipboard/package/lifecycle vectors

- WM: move/resize/minimize/restore; two calculators focused separately with unmixed state; close → reap verified; relaunch clean; malformed/stalled/disconnected-client recovery without killing desktop; **disconnect/timeout bound: client response deadline 5 s (proposed gate), 50 repeated close/relaunch cycles, 0 leaked PIDs/FDs, ΔRSS ≤ 1 MiB post-cycle** (proposed, §7 baseline).
- Clipboard (numeric roundtrip, second app = `foot` running the selected shell, or `nvim` buffer): compute V1 (`42`) via native input, copy via native input, paste into `foot`/`nvim`, verify exact bytes `42`; type `77` in the second app, copy, paste back into a cleared calculator, verify display `77`.
- Package lifecycle (settings file `~/.config/zk-calculator/settings.json`, key `theme`): set `theme=dark`; remove package → executable absent, settings file preserved with `theme=dark`; reinstall → executable present, `theme=dark` intact; explicit purge → executable absent and settings reset to default `theme=light`; offline-cache install (no network) → present; update-failure injection → previous version intact + booted.
- C1b persistence: save user file + settings change; reboot installed profile → intact; live-ISO vs installer-to-disk separate, ISO removed for the latter.
- Comparator: same observables on exact Vinix reference profile (`run-desktop-amd64.sh --monitor` pattern), bound to its own run/kernel manifest. **Wine amd64:** direct Win64 path (no QEMU-user); **Wine ARM64:** guest QEMU-user translation path, labelled separately. `tests/wine/calculator.c` is a repository Win32 sample, not Microsoft/Cocoa evidence.

Evidence bundle per run: `manifest.json` (all bytes+SHA), `serial.log`, `procs.json` (PID/exe/hash), `events.log` (timestamped input), frames/video + SHA, `results.json`, `packages.log`. Stored under `tests/native-distro/calculator/<run-id>/`.

Calculator C1/C2 remains **mandatory** and **does not** close PHOTON-1. Photon evidence, when a native run exists, is stored under `tests/native-distro/photon-studio/<run-id>/` per [photon-studio.md](photon-studio.md) §6. No such run directory exists today.

## 7. Release governance + staged plan (D5/D6 repaired)

Calculator (C1a, then C1b, then C2) closes only its slice. Photon (PHOTON-1) closes only the Photon Flatpak contract and **does not** close calculator. Production needs the full Vinix matrix (§7/V1–V5 in parent), desktop suite (§5), installer/update/rollback/recovery, integrity/security/soak/reproducibility/hardware passes + R1 **and PHOTON-1**. Gates stay open truthfully; no cherry-picked parity. P0 D1-only preview cannot close Photon. P2 cannot ship while PHOTON-1 is `not_run` or `blocked_prerequisites`.

**Stages (commands labelled PLANNED until they exist):**

| Stage | Depends | Exit gate |
| --- | --- | --- |
| S0 RBM + inventory | — | KWP1: RBM, stale-doc sweep |
| S1 boot/traps (EFI baseline; Limine only via gated adapter) | S0 | Z1 (+ N1/N5 GetMemoryMap repair) |
| S2 CPL3 `/init` probe (KWP3a, cpio/newc root) | S1 | Z2-fragment: `PLANNED: scripts/qualify-native/qualify.py --lane init-probe` |
| S3 process/MM/SMP | S2 | Z2–Z3 |
| S4 storage | S2–S3 | Z4 |
| S5 UAPI tiers → static BusyBox → musl dynamic → Python threads/async/mp | S3–S4 | Z5, LNX0–LNX3 |
| S6 devices/net/security (framebuffer/input drivers live here) | S3–S5 | Z6–Z7 |
| S7 lifecycle (install/update/rollback) | S1–S6 | Z8 |
| S8a framebuffer compositor + C1a (boot/interactive, P0) | S2–S6 | Z9-slice: `PLANNED: ... --lane calculator-c1a` |
| S8b C1b persistence/install (P1) | S7+S8a | Z9-slice: `PLANNED: ... --lane calculator-c1b` |
| S9 Vinix matrix V1–V5 on pinned profile | S5+S8a | V1–V5 |
| S10 Wayland/Hyprland session + C2 + full app matrix | S6–S9 | Z9 (minus hardware). **Does not** close PHOTON-1 without an X11 socket lane + Flatpak stack |
| S11 install ISO + persistence + recovery | S7+S10 | Z9 full (still open without Photon) |
| S12 production hardening (P2) | S11 **and S13/PHOTON-1** | R1 + gates below; **blocked** while PHOTON-1 is open |
| **S13 PHOTON-1 native Flatpak** | S7 + glibc-compat Flatpak/OSTree/bwrap + namespaces/seccomp + **X11 lane** (Xorg or Xwayland in native session) + PulseAudio or verified PipeWire-Pulse + DRI or labelled software-GL; typically after S10/S11 media exist | **PHOTON-1:** `PLANNED: scripts/qualify-native/qualify.py --lane photon-studio` (command labelled PLANNED until it exists). Contract: [photon-studio.md](photon-studio.md), [manifest.json](../tests/native-distro/photon-studio/manifest.json) |

No stage claims the full C1 bundle before its prerequisites: C1b needs S7, C2 needs S10. No stage claims Photon: D1/C1, D2/C2, and Wayland-only S10 cannot close PHOTON-1. S13 is a **production release blocker**, not a wishlist.

### 7.1 Quantitative gates (adopt parent [§11.1](../audits/kernel-distro.md#111-proposed-quantitative-release-defaults) minima, plus GUI bounds — all proposed thresholds, not measured results)

Adopted for desktop profiles: 100 consecutive cold/reboot cycles per firmware/device profile; 24 h one-CPU + 72 h SMP soak; every supported fault point injected ≥once before and after durable commit (skips fail required rows); upgrade + rollback from every supported prior edge incl. interruption before boot-health marking; every advertised device class with RBM tuple + matching tests; 24 h logged-in graphical session + Z9 install/update/recovery workflow.

GUI-specific proposed bounds (P1 baseline: QEMU q35/KVM/4vCPU/8GiB, OVMF pinned; TCG fallback noted; QMP-screendump timestamps + serial event log as measurement):

| Check | Proposed bound |
| --- | --- |
| Calculator/app launch | visible window ≤ 15 s or FAIL |
| Input-to-visible-result | ≤ 1 s median on baseline |
| Cycle stress | 50× open/close/resize/focus/move; 0 leaked PIDs/FDs; ΔRSS ≤ 1 MiB |
| Evidence | counts recorded, required-row skip = FAIL, bundle per §6 |
| Photon launch to visible main window (PHOTON-1) | ≤ 15 s or FAIL (**proposed**; measured: not run) |
| Photon input-to-visible-response | ≤ 1 s median on baseline (**proposed**; measured: not run) |
| Photon cycle/relaunch | 50× WM cycles + 10× relaunch; 0 leaked PIDs/FDs; ΔRSS ≤ 1 MiB (**proposed**; measured: not run) |
| Photon soak | parent 24 h graphical session with Photon launched ≥ once per hour, or a recorded Photon RBM amendment (**proposed**; measured: not run) |

Thresholds calibrate through RBM review; no "resource/perf gates" without values remain. Photon rows stay **proposed vs measured**; never report them as passed without a native run bundle.

## 8. Bibliography + traceability (D7)

Reference identities as recorded in parent [§3.2](../audits/kernel-distro.md#32-local-source-inventory-at-audit-start) (re-pin full archive digests at RBM assembly). Audit-start zig-kernel revision metadata `06bec31c2e38ab9c9de326656631ff5c75ef1c7b` is not this publication tree; this tree is `6c8c8ca0611005e7776f437f381c55a866a67e3c`. Sibling inspection revisions (not content hashes; trees not in this checkout): Linux `28924df2a08f440c73991b83028032c901de2ae4` (local Makefile 7.3.0-rc2), Vinix `e4b95129e6ac12d1ec84f060c5becd6e390db85a` (pre-alpha), Omarchy `590d7d1cf6b61bdada16ca6e6e9d1bf7d1d18da2` (4.0.0.alpha), Torkbot `641cbc5fb63fbdb0930dcf1583bbdf7d3ecfbb12`.

Vinix and Omarchy paths below are **labeled historical local inspection references**, not Markdown links. They are workspace-sibling paths bound to the inspection revisions above; they are not files in this checkout.

| Claim | Historical local inspection (labeled reference; not a Markdown link) |
| --- | --- |
| Alpine/musl, no mlibc bootstrap | `vinix/README.md` lines 87–104; `vinix/build-userland-amd64.sh` lines 9–12 (Alpine 3.21.7, recorded SHA `8cba1ea3…ceac05`). Vinix revision `e4b95129e6ac12d1ec84f060c5becd6e390db85a`. |
| amd64 desktop recipe (q35/std/4vCPU/KVM-TCG, desktop-init) | `vinix/run-desktop-amd64.sh` lines 70–91; `vinix/build-support/init-amd64/desktop-init`; `vinix/build-desktop-amd64.sh` (static musl link, app symlinks). Same Vinix revision. |
| Limine ISO assembly (comparator) | `vinix/build-support/build-amd64-iso.sh` (Limine commit + `BOOTX64`/`limine-uefi-cd` SHA). Same Vinix revision. |
| VAPP v3 per-process IPC | `vinix/desktop/app_process.v` lines 18–25 (magic `0x56415050`, v3). Same Vinix revision. |
| fb/pointer/keyboard ABI | `vinix/desktop/framebuffer.v` (ioctls `0x4600`/`0x4602`); `vinix/desktop/input.v` (32-byte `PointerPacket`); `vinix/desktop/README.md` input section. Same Vinix revision. |
| VSF1 surfaces | `vinix/desktop/vinix_surface.v` (magic `0x31534656`, v1, 48-byte header, XRGB8888). Same Vinix revision. |
| Native calculator shape | `vinix/desktop/calculator_app.v`; `vinix/desktop/README.md` (ui2 model, compiled VML). Same Vinix revision. |
| Wine sample semantics (div-zero `0.0`) | `vinix/tests/wine/calculator.c` lines 26–34; `vinix/docs/wine.md` (amd64 Win64 vs ARM64 translation). Same Vinix revision. |
| apk frontend, Alpine 3.21 tracking | `vinix/build-support/vinix-pkg`. Same Vinix revision. |
| Xorg pin 21.1.16 | `vinix/build-x11-aarch64.sh` line 33. Same Vinix revision. |
| Hyprland aarch64 layer | `vinix/build-hyprland-aarch64.sh`; `vinix/run-hyprland-aarch64.sh`. Same Vinix revision. |
| Scripted input/screenshot pattern | `vinix/desktop/tools/input.py`; `vinix/desktop/tools/screenshot.sh`. Same Vinix revision. |
| Omarchy session/packages | `omarchy/default/wayland-sessions/omarchy.desktop` (uwsm); `omarchy/install/omarchy-base.packages` (`chromium:16`, `foot:42`, `nvim:92`, `omacalc:95`, `omarchy-nvim:98`, `quickshell:112`, portals `143-144`). Omarchy revision `590d7d1cf6b61bdada16ca6e6e9d1bf7d1d18da2`. |
| Smoke envelope → cpio plan | this checkout `src/native/initramfs.zig` (64-B header) + `tools/mkinitramfs.zig` (44-B payload), as documented in [native-bootstrap.md](native-bootstrap.md); KWP3a cpio/newc remains planned |
| Native bootstrap limits | [native-bootstrap.md](native-bootstrap.md) (`linux_replacement_qualified` false; no CPL3/Linux ABI/desktop/Photon) |
| Parent quantities | parent [§11.1](../audits/kernel-distro.md#111-proposed-quantitative-release-defaults) |
| Photon Studio header (static, not a run) | [photon-studio.md](photon-studio.md); [manifest.json](../tests/native-distro/photon-studio/manifest.json) (raw byte scan; no app executed) |
| Photon production gate | parent [§16.4](../audits/kernel-distro.md#164-photon-studio-flatpak-mandatory-production-gate-photon-001-added-2026-09-13) |

Traceability: full desktop ISO (production) → §1+§7+S11–S12/P2 **and S13/PHOTON-1**; Vinix parity → §0 profiles, §3 D1+§3.2 rows, §4 P-musl, §6 comparator, S9; every layer clarified → §2 chain, §3 protocols, §4 packages, §5 apps; calculator evidence → §6 + bundle format; Omarchy semantics → §3 D2/§3.1, §4 P-glibc, §5 matrix; Photon Flatpak → §0 Photon row, §2 Photon bullet, §3.1B/§3.2 Flatpak+X11, §4 overlay, §5 Photon row, §7 S13, [photon-studio.md](photon-studio.md).
