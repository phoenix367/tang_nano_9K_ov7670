/*
 * demo_mcu_apps / roi_collect  --  fixed-ROI alignment guide for sample collection
 *
 * Companion to roi_tm + collect_samples.py. Its only job is to draw the SAME
 * fixed region-of-interest box that roi_tm classifies -- so on the live LCD
 * the user sees exactly where to place their face -- and then PARK doing nothing.
 *
 * Parking matters: the host control script (collect_samples.py) drives the wb_grab
 * port itself (arm a capture, read the ROI pixels out of ch1 PSRAM) to harvest
 * labelled training samples. An idle SERV loop makes no bus accesses, so it never
 * contends with the host for the grab port -- the box stays drawn in the OSD buffer
 * (gateware BSRAM) while the host collects.
 *
 * The ROI geometry (grid step, ROI cell bounds, pillarbox LUTs) is byte-identical
 * to roi_tm.c, so the cells the host samples here are exactly the cells the
 * trained classifier will see in roi_tm. The overlay also raises the camera
 * AGC ceiling + enables AWB (same as roi_tm) for a usable image.
 *
 * Parks; reset the MCU (0xE2) to stop. Host-uploaded overlay -- no reflash.
 */
#include <stdint.h>
#include "serv_io.h"

/* fixed ROI in grid cells -- MUST match roi_tm.c (cam_col = cc*16, cam_row = rr*30) */
#define ROI_C0 9
#define ROI_C1 30
#define ROI_R0 1
#define ROI_R1 14

/* OSD box-drawing glyphs (OSD charset C1 codes) */
#define BX_H 0x80
#define BX_V 0x81
#define BX_TL 0x82
#define BX_TR 0x83
#define BX_BL 0x84
#define BX_BR 0x85

/* camera SCCB registers via the EXT window */
#define CAM(reg) (*(volatile uint8_t *)(EXT + (reg)))

/* grid col cc -> OSD col / grid row rr -> OSD row, accounting for the LCD pillarbox
 * (the 640-wide image occupies OSD cols ~7..51). Identical to roi_tm.c. */
static const uint8_t col_lut[40] = {
	7, 8,10,11,12,13,14,15,16,17,19,20,21,22,23,24,25,27,28,29,
	30,31,32,33,34,36,37,38,39,40,41,42,44,45,46,47,48,49,50,51
};
static const uint8_t row_lut[16] = { 0,1,2,3,4,5,6,7,9,10,11,12,13,14,15,16 };

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

	/* draw the fixed ROI box once (pillarbox-correct), then label the guide */
	box_outline(row_lut[ROI_R0], row_lut[ROI_R1], col_lut[ROI_C0], col_lut[ROI_C1]);
	osd_go(8, 1);
	osd_puts("ROI");

	HEARTBEAT = 0x42;                /* liveness marker: overlay drew the box, idling */

	/* park: no bus traffic, so the host owns the grab port for sample collection */
	for (;;)
		;
}
