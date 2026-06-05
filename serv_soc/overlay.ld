/* Linker script for SERV overlay firmware: links at OVERLAY (0x1000), where the
 * bootloader copies it and jumps. Must match OVERLAY in bootloader.S. */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x00001000;
  .text : { *(.text) }
  .data : { *(.data) }
  .bss  : { *(.bss) }
}
