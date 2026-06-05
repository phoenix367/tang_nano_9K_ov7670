/*
 * Minimal C runtime for SERV overlays. Unlike the hand-written asm overlays, C
 * code needs a stack and zeroed .bss, so this startup:
 *   - points sp at the top of the 8 KB RAM (0x2000; the overlay lives at 0x1000,
 *     its data grows up, the stack grows down -- no collision for a tiny demo),
 *   - zeroes the .bss section,
 *   - calls main(),
 *   - and on return hands control back to the bootloader at 0x0000, so the
 *     overlay is re-loadable without a device reset (like the asm demos).
 *
 * Placed in .text.init, which the C overlay linker script puts first, so _start
 * sits at the overlay entry (0x1000) where the bootloader jumps.
 */
	.section .text.init, "ax"
	.globl _start
_start:
	li   sp, 0x2000             /* top of RAM */

	la   t0, __bss_start
	la   t1, __bss_end
1:	bgeu t0, t1, 2f
	sw   zero, 0(t0)
	addi t0, t0, 4
	j    1b
2:
	call main
	li   t0, 0
	jr   t0                     /* return to the bootloader (0x0000) */
