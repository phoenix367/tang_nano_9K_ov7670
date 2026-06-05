/*
 * demo_mcu_apps / motion  --  background-subtraction motion detector
 *
 * Runs on the SERV soft core. It uses the ch1 PSRAM frame-grab path and the OSD:
 *
 *   1. grab a camera frame into ch1 PSRAM,
 *   2. sample NS pixels spread across that frame and SAVE them as a background
 *      model in a FREE region of PSRAM (well above the frame),
 *   3. loop: grab a new frame, re-sample the same points, compare each against
 *      the saved background, and report "Movement: YES/NO" + the changed-sample
 *      count on the OSD. Each iteration also writes a status word to the heartbeat
 *      register (0xE0) -- {iteration counter, verdict bit} -- which the host can
 *      read race-free (the OSD readback races the MCU on the shared cursor).
 *
 * A sample is one camera pixel (the high half of a burst's word0, read via the
 * wb_grab read port). "Changed" = the RGB565 brightness differs from the saved
 * background by more than THRESH; MINCNT changed samples means motion.
 *
 * This overlay PARKS (monitors forever); reset the MCU (Modbus 0xE2, or the
 * webapp's "Reset MCU") to return to the bootloader and load something else.
 *
 * Device access is the shared demo_mcu_apps/common/serv_io.h. The sample/address
 * math is done incrementally (running adds) so RV32I needs no multiply. Linked at
 * 0x1000 (serv_soc/overlay_c.ld).
 */
#include <stdint.h>
#include "serv_io.h"

#define NS        48u            /* number of sample points across the frame */
#define SSTRIDE   397u           /* burst stride between samples (not a multiple */
                                 /* of 40, so samples spread in row AND column) */
#define SSTEP     (SSTRIDE * 16u)/* address step between samples (burst = 16 addr) */
#define BG_BASE   0x80000u       /* free ch1 address for the background model */
                                 /* (frame ends ~0x4B000; samples step by 16) */
#define THRESH    12             /* per-sample brightness-diff threshold */
#define MINCNT    4u             /* >= this many changed samples -> movement */

/* RGB565 -> a rough brightness (sum of the R/G/B channel values, no weighting) */
static int brightness(uint16_t p)
{
	int r = (p >> 11) & 0x1F;
	int g = (p >> 5)  & 0x3F;
	int b =  p        & 0x1F;
	return r + g + b;
}

static int iabs(int x)
{
	return x < 0 ? -x : x;
}

static char hexd(unsigned v)
{
	v &= 0xF;
	return (char)(v < 10 ? '0' + v : 'A' + v - 10);
}

void main(void)
{
	osd_clear_enable();
	while (!psram_calibrated())              /* ch1 must be up before we grab */
		;

	osd_at(8, 23);
	osd_puts("Motion detect");

	/* ---- build the background model from the first frame, save to free PSRAM ---- */
	osd_at(10, 23);
	osd_puts("modeling bg..");
	psram_grab_frame();
	{
		uint32_t src = 0;                /* sample address in the grabbed frame */
		uint32_t dst = BG_BASE;          /* background-model address (free PSRAM) */
		for (unsigned i = 0; i < NS; i++) {
			psram_write16(dst, psram_read16(src));
			src += SSTEP;
			dst += 16u;
		}
	}

	/* ---- monitor loop ---- */
	for (unsigned iter = 0; ; iter++) {
		psram_grab_frame();

		unsigned changed = 0;
		uint32_t src = 0;
		uint32_t bg  = BG_BASE;
		for (unsigned i = 0; i < NS; i++) {
			int now = brightness(psram_read16(src));
			int ref = brightness(psram_read16(bg));
			if (iabs(now - ref) > THRESH)
				changed++;
			src += SSTEP;
			bg  += 16u;
		}
		unsigned moved = (changed >= MINCNT);

		/* race-free status for the host: iteration counter + verdict bit */
		HEARTBEAT = (uint16_t)((iter << 1) | moved);

		osd_at(10, 23);
		osd_puts(moved ? "Movement: YES" : "Movement: NO ");
		osd_at(11, 23);
		osd_puts("changed: 0x");
		osd_putc(hexd(changed >> 4));
		osd_putc(hexd(changed));
	}
}
