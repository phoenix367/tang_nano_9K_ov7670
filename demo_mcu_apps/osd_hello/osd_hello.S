/*
 * demo_mcu_apps / osd_hello
 *
 * The first SERV MCU demo overlay: after the bootloader hands it control, it
 * shows "Hello from MCU!!!" on the OSD overlay. Upload it with the web app's
 * Firmware tab or modbus_client.serv_boot_load(); see doc/serv.md.
 *
 * Runs on the SERV soft core as a Wishbone master. The OSD control registers are
 * not word-aligned in the device register map, so SERV uses byte/halfword stores
 * and serv_wb_cdc extracts the value from the addressed lane.
 *
 * Linked at 0x1000 (serv_soc/overlay.ld). The OSD is blank at boot (the wb_osd
 * reset runs a clear sweep), so we just enable + write.
 */
#define EXT       0x40000000   /* SERV ext window; low 16 bits = device register */
#define OSD_CTRL  0xFB         /* bit0 = enable, bit1 = clear */
#define OSD_ADDR  0xFC         /* char-cell cursor (row*60 + col) */
#define OSD_DATA  0xFD         /* char at cursor; cursor auto-increments */
#define CURSOR    501          /* row 8, col 21 -> centers a 17-char line on 60 cols */

	.globl _start
_start:
	li   a0, EXT
	li   t0, 1
	sb   t0, OSD_CTRL(a0)        /* enable the OSD overlay */
	li   t0, CURSOR
	sh   t0, OSD_ADDR(a0)        /* place the cursor */
	la   t1, msg
write:
	lbu  t0, 0(t1)              /* next char of the message (from RAM) */
	beqz t0, done
	sb   t0, OSD_DATA(a0)        /* write it; cursor auto-increments */
	addi t1, t1, 1
	j    write
done:
	j    done                   /* park the CPU */

	.data
msg:
	.asciz "Hello from MCU!!!"
