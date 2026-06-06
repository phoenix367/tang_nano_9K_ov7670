/*
 * demo_mcu_apps / osd_hello
 *
 * The first SERV MCU demo overlay: after the bootloader hands it control, it
 * clears + enables the OSD, writes "Hello from MCU!!!" centered on it, then
 * RETURNS CONTROL TO THE BOOTLOADER so the host can load another overlay without
 * resetting the device (the bootloader re-arms when SERV reads BOOT_LEN). Upload
 * with the web app's Firmware tab or modbus_client.serv_boot_load(); see
 * doc/serv.md.
 *
 * Runs on the SERV soft core as a Wishbone master. The OSD registers are not
 * word-aligned in the device map; SERV uses byte/halfword stores and serv_wb_cdc
 * resolves the register (word_addr + lane_offset) and extracts the value.
 *
 * Linked at 0x1000 (serv_soc/overlay.ld); the bootloader is at 0x0000.
 */
#define EXT       0x40000000   /* SERV ext window; low 16 bits = device register */
#define OSD_CTRL  0xFB         /* bit0 = enable, bit1 = clear (blank the buffer) */
#define OSD_ADDR  0xFC         /* char-cell cursor (row*60 + col) */
#define OSD_DATA  0xFD         /* char at cursor; cursor auto-increments */
#define CURSOR    501          /* row 8, col 21 -> centers a 17-char line on 60 cols */
#define BOOTLOADER 0x0000      /* bootloader _start */

	.globl _start
_start:
	li   a0, EXT
	li   t0, 3                  /* clear sweep (bit1) + enable (bit0) */
	sb   t0, OSD_CTRL(a0)
	li   t2, 512                /* wait out the ~1020-cycle (38 us) clear sweep */
clrwait:
	addi t2, t2, -1
	bnez t2, clrwait
	li   t0, CURSOR
	sh   t0, OSD_ADDR(a0)       /* place the cursor */
	la   t1, msg
write:
	lbu  t0, 0(t1)             /* next char of the message (from RAM) */
	beqz t0, done
	sb   t0, OSD_DATA(a0)       /* write it; cursor auto-increments */
	addi t1, t1, 1
	j    write
done:
	li   t0, BOOTLOADER
	jr   t0                     /* hand control back to the bootloader */

	.data
msg:
	.asciz "Hello from MCU!!!"
