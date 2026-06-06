/*
 * demo_mcu_apps / psram_test  (C port of the original psram_test.S)
 *
 * Runs on the SERV soft core. It exercises channel-1 PSRAM through the wb_grab
 * write/read port and shows live progress on the OSD:
 *
 *   1. write a pseudo-random 16-bit sequence into NREG PSRAM bursts (one value
 *      per burst, via the high half of the 32-bit burst word), filling a "write"
 *      progress bar,
 *   2. read each burst back and compare against the regenerated sequence, filling
 *      a "read" progress bar,
 *   3. print "PSRAM test: PASS" or "PSRAM test: FAIL" on the OSD,
 *
 * then return -- the common crt0 hands control back to the bootloader so the host
 * can load another overlay without a reset.
 *
 * The cursor is set explicitly before every progress block (the PSRAM bus traffic
 * between blocks would otherwise let the OSD cursor drift). Device access is the
 * shared demo_mcu_apps/common/serv_io.h. Linked at 0x1000 (serv_soc/overlay_c.ld).
 */
#include <stdint.h>
#include "serv_io.h"

#define NREG  512u                     /* number of PSRAM bursts to test */
#define SEED  0xACE1u                  /* pseudo-random generator seed */
#define CHUNK 16u                      /* one bar block per CHUNK bursts -> 32 blocks */

/* small reproducible LCG: x <- (x*5 + 0x1B) & 0xFFFF, written as shift+add so it
 * needs no hardware multiply (SERV is RV32I, no M extension). */
static uint16_t gen(uint16_t x)
{
	return (uint16_t)(((uint32_t)x << 2) + x + 0x1Bu);
}

void main(void)
{
	osd_clear_enable();
	while (!psram_calibrated())            /* wait for ch1 before touching it */
		;

	osd_at(6, 25);
	osd_puts("PSRAM test");

	/* ---- write pass ---- */
	osd_at(9, 8);
	osd_puts("write ");
	unsigned bar = 9 * OSD_COLS + 8 + 6;   /* first write-bar cell */
	uint16_t s = SEED;
	for (unsigned i = 0; i < NREG; i++) {
		s = gen(s);
		psram_write16(i * 16u, s);
		if (((i + 1) & (CHUNK - 1)) == 0) {
			OSD_ADDR = (uint16_t)bar++;    /* position explicitly, then draw */
			OSD_DATA = OSD_BLOCK;
		}
	}

	/* ---- read pass: regenerate the sequence and compare ---- */
	osd_at(10, 8);
	osd_puts("read  ");
	bar = 10 * OSD_COLS + 8 + 6;
	s = SEED;
	int fail = 0;
	for (unsigned i = 0; i < NREG; i++) {
		s = gen(s);
		if (psram_read16(i * 16u) != s)
			fail = 1;
		if (((i + 1) & (CHUNK - 1)) == 0) {
			OSD_ADDR = (uint16_t)bar++;
			OSD_DATA = OSD_BLOCK;
		}
	}

	/* ---- verdict ---- */
	osd_at(12, 22);
	osd_puts(fail ? "PSRAM test: FAIL" : "PSRAM test: PASS");
}
