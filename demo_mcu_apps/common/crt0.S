/*
 * Common C runtime for SERV overlays (shared by every C demo in demo_mcu_apps).
 *
 * The hand-written asm overlays need no runtime, but C code needs a stack and
 * zeroed .bss, so this startup:
 *   - points sp at the top of the 16 KB RAM (0x4000; the overlay lives at 0x1000,
 *     its data grows up, the stack grows down -- no collision),
 *   - zeroes the .bss section (__bss_start/__bss_end from overlay_c.ld),
 *   - calls main(),
 *   - and on return hands control back to the bootloader at 0x0000, so the
 *     overlay is re-loadable without a device reset (like the asm demos).
 *
 * Placed in .text.init, which overlay_c.ld puts first, so _start sits at the
 * overlay entry (0x1000) where the bootloader jumps.
 */
	.section .text.init, "ax"
	.globl _start
_start:
	li   sp, 0x4000             /* top of the 16 KB RAM */

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
