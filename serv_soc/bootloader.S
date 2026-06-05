/*
 * SERV bootloader.
 *
 * SERV has no host channel of its own, so the host (over Modbus) writes the
 * overlay firmware word-by-word into the wb_sysregs mailbox and this bootloader
 * -- running as a Wishbone master -- polls the mailbox, copies the overlay into
 * RAM at OVERLAY, and jumps to it. The mailbox registers are word-aligned in the
 * device register map so RV32I lw/sw are aligned (be_addr = byte adr[15:0]).
 *
 * Protocol (see doc/serv.md):
 *   host: write BOOT_LEN = #16-bit words (sets STATUS.start)
 *         for each word: wait STATUS.pending==0, write BOOT_DATA
 *   serv: wait start; read BOOT_LEN; loop len times {wait pending; read BOOT_DATA
 *         (clears pending); sh to OVERLAY+2*i}; jr OVERLAY.
 */
#define EXT_BASE     0x40000000   /* SERV ext (peripheral) window; low 16b = reg */
#define BOOT_LEN     0xE4         /* byte offset within the window */
#define BOOT_DATA    0xE8
#define BOOT_STATUS  0xEC
#ifndef OVERLAY                  /* overlay load/run address; CMake passes -DOVERLAY= */
#define OVERLAY      0x400        /* from platform.json serv_mcu.overlay_base */
#endif

	.globl _start
_start:
	li   a0, EXT_BASE

wait_start:
	lw   t0, BOOT_STATUS(a0)      /* bit1 = start (host wrote BOOT_LEN) */
	andi t0, t0, 2
	beqz t0, wait_start

	lw   t1, BOOT_LEN(a0)         /* number of 16-bit words to receive */
	li   t2, OVERLAY             /* destination pointer */
	li   t3, 0                   /* word index */

copy_loop:
	beq  t3, t1, run             /* received all words -> run the overlay */
wait_word:
	lw   t0, BOOT_STATUS(a0)      /* bit0 = pending (a word is waiting) */
	andi t0, t0, 1
	beqz t0, wait_word
	lw   t0, BOOT_DATA(a0)        /* read the word (clears pending) */
	sh   t0, 0(t2)               /* store its low 16 bits into the overlay */
	addi t2, t2, 2
	addi t3, t3, 1
	j    copy_loop

run:
	li   t0, OVERLAY
	jr   t0                      /* hand control to the loaded overlay */
