# Native x86_64 UEFI bootstrap

Zig 0.16 first-slice native bootstrap: PE32+ UEFI loader, ELF64 kernel payload,
FAT16 ESP, and a smoke initramfs envelope. It is **not** a Linux replacement,
does not enter CPL3, does not boot Alpine or any other userspace, and is not a
desktop, Photon, or production isolation product.

Hosted `zig build` / `zig build test` and the i386 `qemu-bin` demo remain
separate paths. This guide covers only the opt-in native targets.

## Build and test (Zig 0.16.0)

From a checkout of this tree, with Zig 0.16.0 on `PATH`:

```sh
zig build native-tools
zig build native-image
zig build test-native
zig build test-native-qualification
zig build native-kernel-n6-negative
zig build native-kernel-n6-restore-fail
```

Equivalent portable qualifier-unit run (same suite as `test-native-qualification`):

```sh
python -B scripts/qualify-native/run-tests.py
```

On Windows, Zig 0.16.0 must be on `PATH`. Zig cache, `--prefix`, and
qualifier scratch must be on `D:`. Portable examples may use
checkout-relative paths; Windows examples should pass explicit D-drive
directories:

```powershell
$zig = (Get-Command zig).Source
$scratch = "D:\scratch"
$env:PYTHONDONTWRITEBYTECODE = "1"
$env:QUALIFY_TEST_SCRATCH = "$scratch\qualify-tests"
& $zig build native-image test-native native-tools `
  native-kernel-n6-negative native-kernel-n6-restore-fail `
  --cache-dir "$scratch\zig-cache" `
  --global-cache-dir "$scratch\zig-global-cache" `
  --prefix "$scratch\out" `
  --summary all
python -B scripts/qualify-native/run-tests.py
```

`test-native` is the hosted native contract graph (78 tests). It does not boot
QEMU. `test-native-qualification` / `run-tests.py` are host fixtures for the
public qualifier; they do not launch a guest.

## Artifact contract

`zig build native-image` installs:

| Artifact | Role |
| --- | --- |
| `bin/BOOTX64.efi` | PE32+ / AMD64 EFI application loader |
| `bin/zk-kernel` | ELF64 x86_64 freestanding payload, loaded at 2 MiB |
| `native/initramfs.bin` | 108-byte `INITRMF1` smoke envelope |
| `native/esp.img` | 64 MiB raw FAT16 ESP |

ESP volume paths (no aliases):

- `/EFI/BOOT/BOOTX64.EFI`
- `/ZK/KERNEL.ELF`
- `/ZK/INITRD.BIN`

The initramfs is a 64-byte `INITRMF1` header plus a 44-byte smoke payload
(108 bytes total). It is **not** a root filesystem, cpio archive, or `/init`
userspace. A real file table is out of scope for this slice.

Host tools from `zig build native-tools`: `mkinitramfs`, `mkesp`, `imginfo`.

## Public qualifier pins

`scripts/qualify-native/qualify.py` copies the four artifacts into a fresh
per-run snapshot. `imginfo` inspects PE/ELF metadata of the snapshot loader
and kernel. `scripts/qualify-native/fat16.py` verifies that the embedded ESP
bytes at `/EFI/BOOT/BOOTX64.EFI`, `/ZK/KERNEL.ELF`, and `/ZK/INITRD.BIN` are
identical to those snapshots. The snapshot ESP then boots under pinned
Docker/QEMU **TCG only**.

Required arguments: `--esp-image`, `--loader`, `--kernel`, `--initramfs`,
`--imginfo`, `--evidence-parent`. Optional `--docker-host` / `--docker-config`
override the process Docker context; the qualifier never discovers private
ancestor config directories.

The verifier image identifier and firmware digests live in
`scripts/qualify-native/probe.py` and are required as-is:

| Pin | Value |
| --- | --- |
| Image ref | `zig-kernel-qemu-verifier:local` |
| Image ID | `sha256:8385adfe772b198700e89273eb4d4243f89ee6c1e3367bf2661f1a0d33c9e458` |
| OVMF_CODE.fd | `d9b568def24088c92f34b5479e0ed7e44d0a4d4cea8a0f5716719180bba48106` |
| OVMF_VARS.fd | `6ed987af3a3c155be71665f510eae3e007eda9b8b94afd59d45e91c4a11565cc` |

Machine: q35, cpu qemu64, TCG, 256 MiB RAM, read-only OVMF code plus a
per-run writable VARS copy, serial evidence, isa-debug-exit.

A missing Docker daemon, missing pinned verifier image, or missing
`imginfo`/input artifact is **unavailable** (exit 2), never a pass. An
observed OVMF firmware hash mismatch is recorded as a probe failure and
`qualify.py` returns **fail** (exit 1). A fresh unpinned image does not
satisfy the pin and must remain unavailable. The pin is required as-is; this
slice does not publish, rebuild, or redistribute the verifier image.

```sh
python -B scripts/qualify-native/qualify.py \
  --esp-image zig-out/native/esp.img \
  --loader zig-out/bin/BOOTX64.efi \
  --kernel zig-out/bin/zk-kernel \
  --initramfs zig-out/native/initramfs.bin \
  --imginfo zig-out/bin/imginfo \
  --evidence-parent ./qualify-native-evidence \
  --qemu-accel tcg
```

On Windows, `--imginfo` is `imginfo.exe` and `--evidence-parent` must resolve
to a D-drive directory.

## QEMU TCG expectations

Positive smoke (default `zk-kernel`):

- Ordered loader/kernel stages, then `ZKN: done` and `ZKN: exit code=10`
- QEMU/attached process exit **33**
- Exactly one `trap-ud2-ok` with vector 6 / count **64**
- Unmapped PF vector 14 / code 0 / count **64** / CR2 `0x11000000`
- RO-write PF vector 14 / code 3 / count **64**
- NX-fetch PF vector 14 / code `11` (hex) / count **64**
- Timer ticks **>= 32**
- No PANIC/FAULT and no contradictory exits

Wrong-site UD2 (`zig build native-kernel-n6-negative` →
`zk-kernel-n6-negative`):

- Stages through `pmm-ok`, then
  `ZKN: FAULT uncontrolled vector=6 code=0 rip=000000000020006b`
- No `trap-ud2-ok`, `done`, or success exit
- Handler CLI/HLTs; bounded outer timeout, typically status **124**
- Timeout without that fault/prefix is a failed experiment, not a pass

Skip FXRSTOR (`zig build native-kernel-n6-restore-fail` →
`zk-kernel-n6-restore-fail`):

- Stages through `pmm-ok`; first UD2 returns without FXRSTOR
- No `trap-ud2-ok` or `done`
- `ZKN: exit code=14` (hex) → QEMU/attached process exit **41**
- An unrelated fault or timeout is not proof of this negative

These two images are **not** default success kernels. Relabelling their
raw-fail outcomes as qualifier passes is incorrect.

## Isolated bootstrap qualification (source of this slice)

The native sources in this PR match the reviewed isolated set. Independent
isolated evidence, before this clean-tree integration:

| Gate | Result |
| --- | --- |
| `native-image` | 9/9 steps, exit 0 |
| `test-native` plus both negative kernel builds | 31/31 steps, **78/78** tests, exit 0 |
| Qualifier host regressions (N7 residual) | **54/54** tests, exit 0 |
| N6 focused hosted control-state fixtures | **5/5**, exit 0 |
| QEMU TCG | three accepted positive boots (guest exit 33); wrong-site raw fail / timeout **124**; skip-FXRSTOR raw fail / host **41** |

Positive isolated kernel SHA-256:
`a55100e01869d1ceb2b61b9e7c74f82a21ea89bdf304a50914af6d6d3ebe6cc3`.

Disassembly of those three isolated artifacts found SSE, FXSAVE64/FXRSTOR64,
FNINIT, and a guarded XGETBV policy check. No AVX/YMM/ZMM and no XSAVE/XRSTOR
instructions. That is a declared FXSAVE-profile baseline, not extra CPU-state
support.

An earlier boot of the same positive isolated artifact timed out at 30s
firmware (raw exit 124) before the three accepted boots. That timeout is
retained as a failed attempt, not a pass. The three later positive 55s
boots are smoke evidence, not a production reliability claim.

These results qualify the **isolated** bootstrap sources and artifacts only.
They do not prove a later integrated binary, generic image reproducibility, or
distribution of the pinned verifier.

## Selected reviewed source hashes

| Path | SHA-256 |
| --- | --- |
| `src/native/main.zig` | `ce4ebabd81dfb8680866db713ac428f9aaa531ec5e71e9b328f01dd9ddde36a7` |
| `src/arch/x86_64/native/idt.zig` | `dbbcbf3372bf921b004fe7a6a538b2875833d896a58c759f98c09631eafb356c` |
| `src/arch/x86_64/native/probes.zig` | `7fdd02fbb4a5b9b25cfd7e06bf11100a2acf1bf19bc3583c342a7f6583540ee6` |
| `src/native/n6_negative_root.zig` | `d18829143d36de2d2770627d4c1d294cc831fae0429d0f2c3b14b02ddaf44a25` |
| `src/native/n6_restore_fail_root.zig` | `a7d7d1eba43d5f4eef15d4b5f107a7eca55839dfdb311c7e28b17f5f5cf6294c` |
| `boot/uefi/main.zig` | `951a1f78bf03bf5f674abc904f816d4fe29bebe3043f021c3979fd347b1a1259` |
| `scripts/qualify-native/probe.py` | `c6ffd274121a1b84fbf87839d207d68d2042acf6331a2ffeaa8164cdfa86529a` |
| `scripts/qualify-native/qualify.py` | `df8a637718c2ffd213fb166f92b35ee13e161ff886fff3d983c77f73749c0f96` |
| `scripts/qualify-native/run-tests.py` | `380f399c402227707605117ff2d6c548dfd9f0f3a4f1cd055aa710b070af232f` |

## Limits

- No Linux ABI, syscall table, or userspace compatibility claim
- No CPL3 / ring-3 process, Alpine, desktop, or Photon-studio claim
- No SMP, AVX, XSAVE, #DF/IST, or security-production isolation claim
- Hosted tests are not QEMU evidence; QEMU TCG smoke is not a Linux boot
- `linux_replacement_qualified` is always false

## Clean-tree integration (this checkout)

Rebuilt from `origin/main` plus the 42-file native set. Hosted native tests
and image/tool/negative kernel builds were actually run here:

| Command | Result |
| --- | --- |
| `zig build test-native` | **78/78** tests, 25/25 steps, exit 0 |
| `zig build native-image` | **9/9** steps, exit 0 |
| `zig build native-tools` | 7/7 steps, exit 0 |
| `zig build native-kernel-n6-negative` | 3/3 steps, exit 0 |
| `zig build native-kernel-n6-restore-fail` | 3/3 steps, exit 0 |
| `python -B scripts/qualify-native/run-tests.py` | **54/54** tests, exit 0 |
| `zig build test` (retained hosted) | 58/58 tests, exit 0 |
| `zig build test-supervisor` | 26/26 tests, exit 0 |

Rebuilt kernel identities match the isolated artifacts that had the three
positive / two negative QEMU TCG runs above:

| Artifact | SHA-256 | Bytes |
| --- | --- | --- |
| `zk-kernel` | `a55100e01869d1ceb2b61b9e7c74f82a21ea89bdf304a50914af6d6d3ebe6cc3` | 21056 |
| `zk-kernel-n6-negative` | `04bd94e29da6c87bb17c00197de6cf1a345052a4996450bc2d6f20ffcb0d2bfb` | 21008 |
| `zk-kernel-n6-restore-fail` | `8de3d694a0b6ead448ef224c8ead581dedc99ecee236d234da10d1b55be7300f` | 21056 |
| `BOOTX64.efi` | `267f517a0a417b3335ad397b5c0e429f5c322d1a930058145f5dd44ee96ebfca` | 107008 |
| `esp.img` | `f87ab82754c19eb441442ecd718c33b9d6286815c7b62c0113584903d7f678d4` | 67108864 |
| `initramfs.bin` | `6806e6340bb5986157f03f0fddbebe16ff7bc0ed329fa0b807099706d3335091` | 108 |

Public `qualify.py` TCG of this checkout's ESP **PASS**:

- Guest/attached process exit **33**, owned-container cleanup **0**
- ESP binding pass: embedded `/EFI/BOOT/BOOTX64.EFI`, `/ZK/KERNEL.ELF`, and
  `/ZK/INITRD.BIN` match the snapshot hashes above
- Firmware hashes match the OVMF pins in `scripts/qualify-native/probe.py`
- `linux_replacement_qualified` is **false**
- Verifier image ID
  `sha256:8385adfe772b198700e89273eb4d4243f89ee6c1e3367bf2661f1a0d33c9e458`

Integrated negative rejection gates (not qualifier passes):

| Image | Accepted raw fail |
| --- | --- |
| `zk-kernel-n6-negative` | timeout **124** |
| `zk-kernel-n6-restore-fail` | host **41** |

These integrated guest results are separate from the isolated three-positive
proof and the retained 30s isolated timeout. They are smoke evidence, not a
production reliability claim. This slice does not publish the pinned
verifier image.
