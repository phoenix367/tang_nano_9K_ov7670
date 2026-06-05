/*
 * demo_mcu_apps / skin_detect  --  skin-region detector with an OSD bounding box
 *
 * A tractable "where's the face-ish blob" demo for the bit-serial SERV core (real
 * face detection -- Viola-Jones / ML -- is far too heavy here; see doc/serv.md).
 * It grabs a camera frame into ch1 PSRAM, samples a coarse GW x GH grid of pixels,
 * classifies each as skin / not-skin by a simple RGB565 rule, finds the bounding
 * box of the skin cells, and draws that box on the OSD with box-drawing glyphs.
 * Detects skin-coloured regions (hands, faces, anything warm/reddish), not faces
 * specifically -- but it shows real per-pixel classification + region analysis
 * running on the MCU.
 *
 * Sampling note: the wb_grab read port returns word0 of a burst, so the MCU can
 * only read pixels at burst-aligned addresses (every 16th column). The grid uses
 * cam_col = cc*16 (40 columns across 640) and cam_row = rr*30 (16 rows across
 * 480); the pixel address is built incrementally (no multiply -> no libgcc).
 *
 * OSD: row 0 is a static header; the box is drawn in rows 1..16. The previous box
 * is erased each frame so only the current region is shown. Heartbeat (0xE0) =
 * frame counter (liveness). Parks; reset the MCU (0xE2) to stop it.
 */
#include <stdint.h>
#include "serv_io.h"

#define GW       40            /* sample columns: cam_col = cc*16 (0..624) */
#define GH       16            /* sample rows:    cam_row = rr*30 (0..450) */
#define COL_STEP 16            /* pixel-address step per sample column */
#define ROW_STEP 19200         /* pixel-address step per sample row (30*640) */
#define MINCELLS 6             /* >= this many skin cells -> draw a region box */

/* OSD box-drawing glyphs (charset 0x80..0x9F; see webapp/osd_charset.py) */
#define BX_H  0x80             /* horizontal -- */
#define BX_V  0x81             /* vertical | */
#define BX_TL 0x82             /* corner ,- */
#define BX_TR 0x83             /* corner -, */
#define BX_BL 0x84             /* corner '- */
#define BX_BR 0x85             /* corner -' */
#define SP    0x20             /* space (erase) */

static uint8_t skin[GH * GW];  /* per-cell skin classification (.bss, zeroed by crt0) */

/* OV7670 camera registers reachable through the EXT window (0x00..0xC9 -> wb_sccb).
 * The MCU writes them once at startup to get a usable exposure for skin detection. */
#define CAM(reg) (*(volatile uint8_t *)(EXT + (reg)))
#define CAM_COM8 0x13     /* AEC/AWB/AGC enables */
#define CAM_COM9 0x14     /* AGC gain ceiling */

/* RGB565 skin-tone test: warm (R > G > B by a margin), bright enough but not
 * blown-out white. Tuned against captured frames; thresholds are easy to retune
 * here for your lighting. */
static int is_skin(uint16_t p)
{
	int r  = (p >> 11) & 0x1F;        /* R 0..31 */
	int g5 = (p >> 6)  & 0x1F;        /* G 0..63 -> top 5 bits, comparable to R/B */
	int b  =  p        & 0x1F;        /* B 0..31 */
	return (r > g5) && (g5 >= b) && (r - b >= 4) && (r >= 11) && (r <= 26);
}

/* set the OSD cursor to (row,col) without a multiply: 60*row = (row<<6)-(row<<2) */
static inline void osd_go(unsigned row, unsigned col)
{
	OSD_ADDR = (uint16_t)(((row << 6) - (row << 2)) + col);
}

/* draw (erase=0) or clear (erase=1) a box outline over OSD rows [top..bot],
 * cols [left..right]. Horizontal edges use the cursor's auto-increment. */
static void box_outline(unsigned top, unsigned bot, unsigned left, unsigned right, int erase)
{
	unsigned w = right - left;
	osd_go(top, left);
	OSD_DATA = erase ? SP : BX_TL;
	for (unsigned i = 1; i < w; i++)
		OSD_DATA = erase ? SP : BX_H;
	OSD_DATA = erase ? SP : BX_TR;

	osd_go(bot, left);
	OSD_DATA = erase ? SP : BX_BL;
	for (unsigned i = 1; i < w; i++)
		OSD_DATA = erase ? SP : BX_H;
	OSD_DATA = erase ? SP : BX_BR;

	for (unsigned r = top + 1; r < bot; r++) {
		osd_go(r, left);  OSD_DATA = erase ? SP : BX_V;
		osd_go(r, right); OSD_DATA = erase ? SP : BX_V;
	}
}

void main(void)
{
	osd_clear_enable();
	while (!psram_calibrated())
		;

	/* brighten the camera for skin detection: raise the AGC gain ceiling
	 * (default ~4x is too dark) and enable auto white balance (fixes a green
	 * cast). These are SCCB writes to the live camera via wb_sccb. */
	CAM(CAM_COM9) = 0x3A;             /* AGC ceiling -> 16x */
	CAM(CAM_COM8) = 0xE7;             /* AEC + AWB + AGC + fast-AEC */

	osd_at(0, 20);
	osd_puts("Skin region detector");

	int pv = 0;                       /* a box is currently drawn */
	unsigned pt = 0, pb = 0, pl = 0, pr = 0;

	for (unsigned frame = 0; ; frame++) {
		psram_grab_frame();

		/* 1) classify every grid cell into `skin[]` */
		uint32_t rowbase = 0;
		unsigned off = 0;
		for (int rr = 0; rr < GH; rr++) {
			uint32_t addr = rowbase;
			for (int cc = 0; cc < GW; cc++) {
				skin[off + cc] = is_skin(psram_read16(addr));
				addr += COL_STEP;
			}
			rowbase += ROW_STEP;
			off += GW;
		}

		/* 2) erode + bound: a cell counts only if it has >= 1 skin neighbour, so
		 * isolated noise cells don't stretch the box to the whole frame. */
		int count = 0, minc = GW, maxc = -1, minr = GH, maxr = -1;
		off = 0;
		for (int rr = 0; rr < GH; rr++) {
			for (int cc = 0; cc < GW; cc++) {
				if (skin[off + cc]) {
					int nb = 0;
					if (cc > 0      && skin[off + cc - 1])  nb++;
					if (cc < GW - 1 && skin[off + cc + 1])  nb++;
					if (rr > 0      && skin[off + cc - GW]) nb++;
					if (rr < GH - 1 && skin[off + cc + GW]) nb++;
					if (nb >= 1) {
						count++;
						if (cc < minc) minc = cc;
						if (cc > maxc) maxc = cc;
						if (rr < minr) minr = rr;
						if (rr > maxr) maxr = rr;
					}
				}
			}
			off += GW;
		}

		/* the new region box: grid col cc -> OSD col cc*1.5 (cc + cc>>1),
		 * grid row rr -> OSD row rr+1 (row 0 is the header) */
		int detect = (count >= MINCELLS);
		unsigned top = 0, bot = 0, left = 0, right = 0;
		if (detect) {
			left  = (unsigned)minc + ((unsigned)minc >> 1);
			right = (unsigned)maxc + ((unsigned)maxc >> 1);
			top   = (unsigned)minr + 1;
			bot   = (unsigned)maxr + 1;
			if (right <= left) right = left + 1;
			if (bot <= top)    bot = top + 1;
		}

		/* only touch the OSD when the box changes -- a stationary region is drawn
		 * once (no per-frame erase/redraw flicker, and the host can read it). */
		int same = pv && detect && top == pt && bot == pb && left == pl && right == pr;
		if (!same) {
			if (pv)
				box_outline(pt, pb, pl, pr, 1);   /* erase the old box */
			if (detect) {
				box_outline(top, bot, left, right, 0);
				pv = 1; pt = top; pb = bot; pl = left; pr = right;
			} else {
				pv = 0;
			}
		}

		HEARTBEAT = (uint16_t)(frame & 0xFFu);   /* liveness for the host */
	}
}
