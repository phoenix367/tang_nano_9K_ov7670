/*
 * demo_mcu_apps / motion_c  --  the motion detector in C (vs the asm `motion`)
 *
 * Functionally identical to demo_mcu_apps/motion/motion.S, written in C so the two
 * can be compared head to head -- in particular their processing FPS, which shows
 * how much overhead the compiler adds over hand assembly on the bit-serial core.
 *
 * Grab a frame -> sample NS pixels -> save a background model in FREE PSRAM; then
 * loop: grab, compare each sample's RGB565 brightness to the background (>= MINCNT
 * changed by > THRESH = movement), refreshing the background every BG_PERIOD
 * frames. Measures its own FPS off the 1 Hz uptime counter. Reports on the OSD
 * ("Motion (C)", "FPS: NN", "Movement: YES/NO", "changed:", "bg refresh:") and
 * publishes the FPS on heartbeat 0xE0 (low byte) for a race-free host read.
 *
 * Parks; reset the MCU (0xE2) to stop it. All math is shifts/masks/adds, so RV32I
 * needs no mul/div (no libgcc). Uses the shared common/ runtime + serv_io.h.
 */
#include <stdint.h>
#include "serv_io.h"

#define NS        48u
#define SSTEP     (397u * 16u)   /* address step between samples (constant add) */
#define BG_BASE   0x80000u       /* free ch1 address for the background model */
#define THRESH    12
#define MINCNT    4u
#define BG_SHIFT  5              /* refresh every 2^BG_SHIFT frames */
#define BG_MASK   ((1u << BG_SHIFT) - 1u)

static int brightness(uint16_t p)
{
	return ((p >> 11) & 0x1F) + ((p >> 5) & 0x3F) + (p & 0x1F);
}

static int iabs(int x) { return x < 0 ? -x : x; }

static char hexd(unsigned v) { v &= 0xF; return (char)(v < 10 ? '0' + v : 'A' + v - 10); }

void main(void)
{
	osd_clear_enable();
	while (!psram_calibrated())
		;
	osd_at(8, 23);  osd_puts("Motion (C)");
	osd_at(12, 23); osd_puts("bg refresh: 0x00");

	/* background model from the first frame -> free PSRAM */
	psram_grab_frame();
	{
		uint32_t src = 0, dst = BG_BASE;
		for (unsigned i = 0; i < NS; i++) {
			psram_write16(dst, psram_read16(src));
			src += SSTEP;
			dst += 16u;
		}
	}

	unsigned fps = 0, fps_count = 0;
	unsigned last_sec = uptime_lo();

	for (unsigned frame = 0; ; frame++) {
		psram_grab_frame();
		int refresh = (frame != 0) && ((frame & BG_MASK) == 0);

		unsigned changed = 0;
		uint32_t src = 0, bg = BG_BASE;
		for (unsigned i = 0; i < NS; i++) {
			uint16_t cur = psram_read16(src);
			uint16_t ref = psram_read16(bg);
			if (iabs(brightness(cur) - brightness(ref)) > THRESH)
				changed++;
			if (refresh)
				psram_write16(bg, cur);    /* adapt the background in place */
			src += SSTEP;
			bg  += 16u;
		}
		unsigned moved = (changed >= MINCNT);

		osd_at(10, 23); osd_puts(moved ? "Movement: YES" : "Movement: NO ");
		osd_at(11, 23); osd_puts("changed: 0x");
		osd_putc(hexd(changed >> 4)); osd_putc(hexd(changed));
		if (refresh) {
			unsigned rc = frame >> BG_SHIFT;   /* refresh count */
			osd_at(12, 37);
			osd_putc(hexd(rc >> 4)); osd_putc(hexd(rc));
		}

		/* processing FPS: iterations between 1 Hz uptime ticks */
		unsigned sec = uptime_lo();
		if (sec != last_sec) {
			fps = fps_count;
			fps_count = 1;
			last_sec = sec;
			osd_at(9, 23); osd_puts("FPS: "); osd_put_dec2(fps);
		} else {
			fps_count++;
		}
		HEARTBEAT = (uint16_t)(fps & 0xFFu);   /* low byte only (0xE0 is 8-bit) */
	}
}
