/*
 * demo_mcu_apps / c_hello
 *
 * The same idea as osd_hello, but written in C instead of assembly: after the
 * bootloader hands it control (via crt0.S, which sets up a stack and zeroes
 * .bss), it clears + enables the OSD and writes "Hello from C!" centered on it,
 * then returns -- crt0 jumps back to the bootloader so the host can load another
 * overlay without a reset.
 *
 * Runs on the SERV soft core as a Wishbone master. The device registers live in
 * the EXT window (low 16 bits = register number); serv_wb_cdc resolves the
 * non-word-aligned OSD registers from the byte address + access width, so plain
 * volatile byte/halfword pointer writes reach the right register (a uint8 store
 * to 0xFB/0xFD, a uint16 store to 0xFC -- exactly the sb/sh the asm demo used).
 *
 * Built with the RISC-V C toolchain; linked at 0x1000 (overlay_c.ld).
 */
#define EXT 0x40000000u                 /* SERV ext window base */

/* OSD control registers (see doc/modbus_server.md) */
#define OSD_CTRL (*(volatile unsigned char  *)(EXT + 0xFBu))  /* bit0=enable bit1=clear */
#define OSD_ADDR (*(volatile unsigned short *)(EXT + 0xFCu))  /* cursor = row*60 + col */
#define OSD_DATA (*(volatile unsigned char  *)(EXT + 0xFDu))  /* char; cursor auto-increments */

#define MSG    "Hello from C!"
#define CURSOR (8 * 60 + 23)            /* row 8, col 23 -> centers a 13-char line */

/* Busy-wait; the volatile counter keeps the compiler from optimizing it away. */
static void delay(int n)
{
	for (volatile int i = 0; i < n; i++)
		;
}

void main(void)
{
	OSD_CTRL = 0x03;                /* clear sweep + enable */
	delay(2000);                    /* let the hardware blank sweep finish */

	OSD_ADDR = CURSOR;
	for (const char *s = MSG; *s; s++)
		OSD_DATA = (unsigned char)*s;   /* cursor auto-increments per char */
}
