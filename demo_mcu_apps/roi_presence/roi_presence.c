/*
 * demo_mcu_apps / roi_presence  --  fixed-ROI face-presence gate
 *
 * Instead of searching the whole frame for a face (far too heavy for the bit-serial
 * core), this draws a FIXED region-of-interest box on the OSD -- the user aligns
 * their face to it -- and classifies just that ROI as face-present / empty each
 * frame. A fixed ROI turns "detection" into a single per-frame classification.
 *
 * The classifier here is a baseline: count skin-classified cells inside the ROI and
 * threshold (a face filling the box -> many skin cells). It is isolated in
 * classify_present() so it can later be swapped for a trained lightweight model
 * (e.g. a Tsetlin Machine running inference on the ROI's LBP features -- bitwise,
 * MCU-friendly; trained offline on the host).
 *
 * The ROI box is drawn once via the pillarbox-correct OSD map (cols 7..51). A
 * "FACE" label in the left border lights up while a face is present. Heartbeat
 * (0xE0) = (skin_count << 1) | present, for the host. Parks; reset (0xE2) to stop.
 * The overlay raises the camera AGC ceiling + AWB at startup (as skin_detect does).
 */
#include <stdint.h>
#include "serv_io.h"

/* sample grid (matches skin_detect): cam_col = cc*16, cam_row = rr*30 */
#define COL_STEP 16
#define ROW_STEP 19200

/* fixed ROI in grid cells (centred where a face sits): cols 13..27, rows 3..12 */
#define ROI_C0 13
#define ROI_C1 27
#define ROI_R0 3
#define ROI_R1 12
#define ROI_CELLS ((ROI_C1 - ROI_C0 + 1) * (ROI_R1 - ROI_R0 + 1))   /* 15*10 = 150 */
#define PRESENCE_THRESH 25     /* >= this many skin cells in the ROI -> face present */

/* OSD box-drawing glyphs */
#define BX_H 0x80
#define BX_V 0x81
#define BX_TL 0x82
#define BX_TR 0x83
#define BX_BL 0x84
#define BX_BR 0x85

/* camera SCCB registers via the EXT window */
#define CAM(reg) (*(volatile uint8_t *)(EXT + (reg)))

/* grid col cc -> OSD col, accounting for the LCD pillarbox (image is cols ~7..51) */
static const uint8_t col_lut[40] = {
	7, 8,10,11,12,13,14,15,16,17,19,20,21,22,23,24,25,27,28,29,
	30,31,32,33,34,36,37,38,39,40,41,42,44,45,46,47,48,49,50,51
};
static const uint8_t row_lut[16] = { 0,1,2,3,4,5,6,7,9,10,11,12,13,14,15,16 };

static int is_skin(uint16_t p)
{
	int r  = (p >> 11) & 0x1F;
	int g5 = (p >> 6)  & 0x1F;
	int b  =  p        & 0x1F;
	return (r > g5) && (g5 >= b) && (r - b >= 4) && (r >= 11) && (r <= 26);
}

/* the swappable presence classifier (baseline: skin coverage in the ROI) */
static int classify_present(int skin_count)
{
	return skin_count >= PRESENCE_THRESH;
}

static inline void osd_go(unsigned row, unsigned col)
{
	OSD_ADDR = (uint16_t)(((row << 6) - (row << 2)) + col);   /* 60*row + col */
}

static void box_outline(unsigned top, unsigned bot, unsigned left, unsigned right)
{
	unsigned w = right - left;
	osd_go(top, left);  OSD_DATA = BX_TL;
	for (unsigned i = 1; i < w; i++) OSD_DATA = BX_H;
	OSD_DATA = BX_TR;
	osd_go(bot, left);  OSD_DATA = BX_BL;
	for (unsigned i = 1; i < w; i++) OSD_DATA = BX_H;
	OSD_DATA = BX_BR;
	for (unsigned r = top + 1; r < bot; r++) {
		osd_go(r, left);  OSD_DATA = BX_V;
		osd_go(r, right); OSD_DATA = BX_V;
	}
}

void main(void)
{
	osd_clear_enable();
	while (!psram_calibrated())
		;
	CAM(0x14) = 0x3A;                /* COM9: AGC ceiling -> 16x */
	CAM(0x13) = 0xE7;                /* COM8: enable AWB */

	/* draw the fixed ROI box once (pillarbox-correct) */
	box_outline(row_lut[ROI_R0], row_lut[ROI_R1], col_lut[ROI_C0], col_lut[ROI_C1]);

	int prev = -1;                   /* last presence state (force first update) */
	for (unsigned frame = 0; ; frame++) {
		psram_grab_frame();

		/* scan only the ROI cells, count skin */
		int count = 0;
		uint32_t rowbase = (uint32_t)ROI_R0 * ROW_STEP;
		for (int rr = ROI_R0; rr <= ROI_R1; rr++) {
			uint32_t addr = rowbase + (uint32_t)ROI_C0 * COL_STEP;
			for (int cc = ROI_C0; cc <= ROI_C1; cc++) {
				if (is_skin(psram_read16(addr)))
					count++;
				addr += COL_STEP;
			}
			rowbase += ROW_STEP;
		}

		int present = classify_present(count);
		if (present != prev) {       /* update the border label only on change */
			osd_go(8, 1);
			osd_puts(present ? "FACE" : "    ");
			prev = present;
		}
		HEARTBEAT = (uint16_t)(((count > 127 ? 127 : count) << 1) | (present & 1));
	}
}
