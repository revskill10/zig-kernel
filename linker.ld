/* Bare-metal ELF for QEMU -kernel direct load (32-bit protected mode) */
OUTPUT_FORMAT(elf32-i386)
ENTRY(_start)
SECTIONS
{
  . = 0x100000;
  .multiboot : { *(.multiboot) }
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) *(COMMON) }
}
