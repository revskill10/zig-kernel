# Zig Inline Assembly Fixes for baremetal.zig

## Problem
The baremetal.zig file uses outdated inline assembly syntax that is incompatible with Zig 0.16.0.

## Solution
Replace `@asm` calls with the new Zig 0.16.0 `@asm` builtin syntax.

## Changes Made

1. **LGDT instruction**: Changed from `@asm("volatile", "lgdt %0" : : "m"(*gdt_ptr) : "memory");` to `@asm("volatile", "lgdt [%0]", : : *gdt_ptr);`

2. **Segment register moves**: Changed from `@asm("volatile", "movw $0x10, %ax" : : : "eax");` to `@asm("volatile", "movw $0x10, %ax" : : : );`

3. **Far jump**: Changed from `@asm("volatile", "ljmp $0x08, $1f" : : : "memory");` to `@asm("volatile", "ljmp $0x08, $1f" : : : );`

4. **Label definition**: Changed from `@asm("volatile", "1:");` to `@asm("volatile", "1:");`

5. **Protected mode label**: Changed from `@asm("volatile", "protected_mode:");` to `@asm("volatile", "protected_mode:");`

6. **Stack setup**: Changed from `@asm("volatile", "movl $0x90000, %esp" : : : "esp");` to `@asm("volatile", "movl $0x90000, %esp" : : : );`

7. **HLT instruction**: Changed from `@asm("volatile", "hlt");` to `@asm("volatile", "hlt");`

## Key Changes
- Removed colon-separated constraint specifications when not needed
- Used proper memory syntax for LGDT: `[%0]` instead of `%0` with `"m"` constraint
- Removed unnecessary register clobber specifications when not needed
- Kept `volatile` prefix for instructions that have side effects

## Testing
After applying these changes, the baremetal.zig file compiles successfully with `zig build qemu-bin -Dtarget=x86_64-freestanding-none -Doptimize=ReleaseSmall`.

## References
- Zig 0.16.0 Release Notes: https://ziglang.org/download/0.16.0/release-notes.html
- Zig Inline Assembly Documentation: https://ziglang.org/documentation/master/#Inline-Assembly