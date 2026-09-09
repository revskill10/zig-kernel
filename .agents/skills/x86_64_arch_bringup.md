# x86_64 Architecture Bring-up — #PF(14) + handle_mm_fault

## Goal
Slice 5 depth t5a: wire IDT[14] #PF and implement handle_mm_fault with demand paging.

## References
- Intel SDM Vol.3 Ch.6 Interrupt & Exception Handling, Ch.4 Paging, #PF vector 14, error code bits (P,W,U,RSVD,I), CR2 fault addr, invlpg
- OSDev: Page Fault, Paging, IDT gate types (0x8E interrupt, 0x8F trap)
- Linux: arch/x86/mm/fault.c do_page_fault() -> handle_mm_fault(), mm/memory.c, paging_init, vm_area_struct, handle_pte_fault
- Existing: src/arch/i386/paging.zig (identity 64MiB), src/arch/i386/idt.zig (IDT[0x80] DPL3), src/baremetal.zig (_start SSE+SMP gate)

## Gate Design
- IDT[14] = #PF, DPL0, present, interrupt gate attr 0x8E (P=1,DPL00,0,1110). Keeps IF cleared. Syscall stays 0xEF (P=1,DPL11,trap 1111).
- Stub `pf_entry` nakeded: pusha, mov CR2->eax, mov 32(%esp)->ebx (error code), push ebx, push eax, call pf_dispatch, add $8, popa, add $4 (skip CPU error_code), iret. Coexists with syscall_entry (pusha/push esp/call/add/popa/iret). Registers restored, no leaks.
- pf_dispatch(fault_addr:u32, error_code:u32) callconv(.c): increment pf_hit_count, save last, call paging.handle_mm_fault.

## Paging Extension
- page_directory [1024]u32 + page_tables [MAX_PT=64][1024]u32 align 4096 (covers 256MiB demand, 64*4MiB). First 16 pre-mapped identity 0x3 (P|RW), rest zero => demand.
- paging_init(): identity first 16, zero directory rest, only if freestanding then mov cr3, cr0.PG. Hosted test skips privileged asm (builtin.target.os.tag check).
- handle_mm_fault(fault_addr, error_code) -> isize: pd=addr>>22, pt=(addr>>12)&1023, frame=addr&~0xFFF, if pd >= MAX_PT => -12 ENOMEM, if directory[pd]==0 then directory[pd]= (&page_tables[pd] & 0xFFFFF000)|0x3, then if page_tables[pd][pt]==0 then page_tables[pd][pt]= frame|0x3| (user bit if error&0x4), else set RW, invlpg fault_addr if freestanding, pf_handled++, return 0. Handles present/W/U bits. TLB flush via invlpg or mov cr3,cr3.
- Helpers: isMapped(vaddr) bool, getPDE/PTE, invlpg wrapper.

## Bare-metal Demo
- In kmain after gdt/idt/paging/serial: print pf gate present, then fault at 0x05000000 (pd=20 unmapped), volatile write 0xDEADBEEF, readback, print hit count, expect 42 via dispatch still, then second fault at 0x06001000.
- Freestanding integer formatters: add serial_writeHex32.

## Hosted Test
- test handle_mm_fault maps unmapped page: init tables (skip cr3), assert directory[20]==0, call handle, assert !=0 and PTE !=0, second call idempotent, out-of-range returns -12.

## Files
- src/arch/i386/paging.zig (expand, handle, test)
- src/arch/i386/idt.zig (PF gate, stub, dispatch)
- src/baremetal.zig (demo, hex32)
- .agents/skills/x86_64_arch_bringup.md (this)

## Verification
- zig build qemu-bin -> ELF32 0x10000c
- zig build test -> handle test pass
- QEMU serial: syscall dispatch 42/-38, pf write/read ok, DEMO complete, KERNEL_HALT
- Branch t5a-mm-pf14, PR, CI green (ELF ok, PASS Kernel started/VFS/Demo/hlt, dist sha).
- Ceiling: full demand with VMA + copy-on-write + swap; ponytail: fixed 64 PT limit, identity RW only, no VMA permission checks, bypass int 0x80 trap still dispatch (restore trap after #GP fix).
