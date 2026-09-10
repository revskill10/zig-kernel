# zk-abi-v1 + guest protocol (M1 freeze)

## ABI

- Arch: x86_64, static ELF64, no dynamic linker.
- Entry: `_start`, stack holds argc argv envp (Linux layout).
- Syscall: `syscall` insn. Numbers = `src/arch/x86_64/entry.zig` `NR` subset.
- v1 subset: `read=3 write=4 openat=2 close=6 seek=5 mmap=1 munmap=34 mprotect=48 exit=15 getpid=31 clock_get=50 nanosleep=53`.
- FDs: 0 stdin 1 stdout 2 stderr. `cwd=/workspace`. Args direct, no shell.
- Rejection: dynamic ELF, non-AMD64, bad headers, bad user pointers → `guest_failure`, no crash.
- `ponytail:` full Linux ABI later; add when agent workload needs Bash/Python.

## Lifecycle

- Sandbox: `creating→ready→busy→ready→resetting→ready→expired/destroying→destroyed`.
- Exec: `queued→running→done(cancelling→done)`.
- Rules: exec only when `ready`. Reset bumps `generation`, kills execs, wipes workspace, rejoins `ready`. Stale generation → `409`.

## Guest protocol (serial/vsock, CBOR frames)

- `hello{image,abi}` → `ready`.
- `exec{id,argv,cwd,env,stdin_len,timeout_ms}` → `started{id}`.
- `stdio{id,fd,data}` chunks, bounded by `output_bytes`.
- `exit{id,terminal,code,reason}` terminal = `exited|cancelled|timeout|resource_limit|output_limit|guest_failure`.
- `file_put{path,len,sha256}` / `file_get{path}` under `/workspace` only. Traversal, symlink escape → error.
- Host enforces timeouts, kills VM on silence. Guest never raises limits.

## Errors

- Codes: `bad_request|not_found|conflict|gone|limit|unsupported|guest_failure`.
- Idempotency-Key required mutating ops. Same key+different body → `409`.
