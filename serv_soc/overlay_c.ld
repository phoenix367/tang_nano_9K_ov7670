/* Linker script for C SERV overlays: links at OVERLAY (0x1000), where the
 * bootloader copies it and jumps. Like overlay.ld but adds the sections a C
 * program needs -- .rodata for string literals, the small-data sections gcc
 * emits, and __bss_start/__bss_end so crt0.S can zero .bss. .text.init (crt0)
 * is placed first so _start lands at the 0x1000 entry. Must match OVERLAY in
 * bootloader.S. */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x00001000;
  .text   : { *(.text.init) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) }
  .data   : { *(.data .data.* .sdata .sdata.*) }
  . = ALIGN(4);
  __bss_start = .;
  .bss    : { *(.bss .bss.* .sbss .sbss.* COMMON) }
  . = ALIGN(4);
  __bss_end = .;
}
