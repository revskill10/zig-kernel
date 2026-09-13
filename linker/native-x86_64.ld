/* linker/native-x86_64.ld — native x86_64 kernel payload (KWP2).
 * Physical identity layout at 2 MiB; the EFI loader validates the resulting
 * ELF64 (ET_EXEC, paddr == vaddr, page-congruent segments) before copying.
 * The whole image must stay inside the first 2 MiB block above the base:
 * the kernel's owned page tables split that block into 4 KiB leaves.
 */
OUTPUT_FORMAT("elf64-x86-64")
OUTPUT_ARCH(i386:x86-64)
ENTRY(kmain)

KERNEL_BASE = 0x200000;

SECTIONS
{
    . = KERNEL_BASE;

    .text : ALIGN(4096) {
        *(.text)
        *(.text.*)
    }

    .rodata : ALIGN(4096) {
        *(.rodata)
        *(.rodata.*)
    }

    .data : ALIGN(4096) {
        *(.data)
        *(.data.*)
    }

    .bss : ALIGN(4096) {
        *(COMMON)
        *(.bss)
        *(.bss.*)
    }

    kernel_end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}

/* Second guard beside the EFI loader's own span check (elf64.zig, N4): the
 * linked payload must stay inside the first 2 MiB block above KERNEL_BASE. */
ASSERT(kernel_end >= KERNEL_BASE, "kernel image does not start at KERNEL_BASE");
ASSERT(kernel_end <= KERNEL_BASE + 0x200000,
    "kernel image exceeds the 2 MiB identity window");
