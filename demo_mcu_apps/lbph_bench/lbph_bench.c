/*
 * demo_mcu_apps / lbph_bench  --  LBPH feature-computation benchmark on SERV
 *
 * Measures how fast the bit-serial SERV core can compute an LBPH (Local Binary
 * Patterns Histogram) feature vector -- the core of the classic OpenCV face
 * recogniser -- to judge whether on-MCU face recognition is viable.
 *
 * The wb_grab read port exposes only word0 (2 pixels) per burst, so the MCU can't
 * densely read a full-resolution face. Instead it reads a DOWNSCALED N x N face
 * (one pixel per burst) into RAM, then runs LBP densely on that in-RAM image:
 *   - per interior pixel: compare luma to its 8 neighbours -> 8-bit LBP code,
 *   - accumulate the code into the histogram of its grid cell (CW x CW cells,
 *     256 bins each) -> the LBPH feature vector (CW*CW*256 bytes).
 *
 * One "pass" = clear histogram + read the downscaled face + compute the LBPH
 * features (what you'd do once per face for recognition). It loops on a single
 * grabbed frame and reports passes/second (timed off the 1 Hz uptime counter) on
 * the OSD and the heartbeat (0xE0). All index math is shifts/adds (N, CW powers
 * of two) so RV32I needs no multiply -> no libgcc.
 *
 * Parks; reset the MCU (0xE2) to stop. Uses the shared common/ runtime.
 */
#include <stdint.h>
#include "serv_io.h"

#define N         32            /* downscaled face is N x N (power of two) */
#define CW        4             /* CW x CW grid of cells (power of two) */
#define CSH       3             /* log2(N/CW): cell = pixel >> CSH */
#define NBINS     256
#define COL_STEP  16            /* PSRAM address step per face column (burst) */
#define ROW_STEP  9600          /* per face row (15 source rows * 640) */

static uint8_t luma[N * N];             /* downscaled face brightness, in RAM */
static uint8_t hist[CW * CW * NBINS];   /* the LBPH feature vector (.bss) */

static inline int brightness(uint16_t p)
{
	return ((p >> 11) & 0x1F) + ((p >> 5) & 0x3F) + (p & 0x1F);   /* 0..125 */
}

/* read the downscaled N x N face from the grabbed frame into luma[] */
static void read_face(void)
{
	uint32_t rowbase = 0;
	unsigned o = 0;
	for (int r = 0; r < N; r++) {
		uint32_t addr = rowbase;
		for (int c = 0; c < N; c++) {
			luma[o++] = (uint8_t)brightness(psram_read16(addr));
			addr += COL_STEP;
		}
		rowbase += ROW_STEP;
	}
}

/* compute the LBPH feature vector of luma[] into hist[] */
static void lbph(void)
{
	for (unsigned i = 0; i < (unsigned)(CW * CW * NBINS); i++)
		hist[i] = 0;

	for (int r = 1; r < N - 1; r++) {
		int p = (r << 5);                       /* r * N (N == 32) */
		int cellrow = (r >> CSH) << 2;          /* (r/8)*CW, CW == 4 */
		for (int c = 1; c < N - 1; c++) {
			int q = p + c;
			int ctr = luma[q];
			int code = 0;
			if (luma[q - N - 1] >= ctr) code |= 0x01;
			if (luma[q - N]     >= ctr) code |= 0x02;
			if (luma[q - N + 1] >= ctr) code |= 0x04;
			if (luma[q - 1]     >= ctr) code |= 0x08;
			if (luma[q + 1]     >= ctr) code |= 0x10;
			if (luma[q + N - 1] >= ctr) code |= 0x20;
			if (luma[q + N]     >= ctr) code |= 0x40;
			if (luma[q + N + 1] >= ctr) code |= 0x80;
			int cell = cellrow + (c >> CSH);
			hist[(cell << 8) + code]++;          /* cell*256 + code */
		}
	}
}

void main(void)
{
	osd_clear_enable();
	while (!psram_calibrated())
		;
	osd_at(6, 18); osd_puts("LBPH feature benchmark");
	osd_at(8, 18); osd_puts("32x32 face, 4x4 cells");

	psram_grab_frame();                  /* one frame; benchmark the feature compute */

	unsigned passes = 0, rate = 0;
	unsigned last = uptime_lo();
	for (;;) {
		read_face();
		lbph();
		passes++;

		unsigned now = uptime_lo();
		if (now != last) {
			rate = passes;
			passes = 0;
			last = now;
			osd_at(10, 18);
			osd_puts("LBPH/s: ");
			osd_put_dec2(rate > 99 ? 99 : rate);
			HEARTBEAT = (uint16_t)(rate & 0xFFu);   /* race-free rate for the host */
		}
	}
}
