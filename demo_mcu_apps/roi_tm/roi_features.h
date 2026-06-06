/*
 * roi_features.h -- the ROI -> literal-vector featurization, shared by the roi_tm
 * overlay and the host regression test (test_tm_pipeline.py compiles this and
 * checks it against tm_common.featurize). Keeping the real C in one header that the
 * test exercises is what catches C-vs-Python divergences -- the Python "mirror"
 * alone missed a macro variable-shadowing bug here once.
 *
 * MUST stay in lockstep with tm_common.py: 2x2 block-average the 22x14 RGB565 ROI
 * to an 11x7 grid, then luma 8-neighbour LBP over the interior (360) + 3 colour
 * bits per cell -- R>G, R>B, skin cue (231) = 591 features. Pure integer compares.
 */
#ifndef ROI_FEATURES_H
#define ROI_FEATURES_H

#include <stdint.h>
#include "tm_model.h"

/* feature grid (MUST match tm_common.py) */
#define ROI_COLS 22
#define ROI_ROWS 14
#define ROI_CELLS (ROI_COLS * ROI_ROWS)
#define DSW (ROI_COLS / 2)
#define DSH (ROI_ROWS / 2)
#define COLOR_CELLS (DSW * DSH)
#define FEATURE_COUNT (((DSW - 2) * (DSH - 2)) * 8 + 3 * COLOR_CELLS)

#if TM_N != FEATURE_COUNT
#error "tm_model.h TM_N disagrees with the feature count -- retrain (train_tm.py)"
#endif

/* set literal `idx` from a feature bit: feature at bit idx, negation at TM_N+idx.
 * Internal index is `_bit` (NOT a single letter) so it can't shadow a caller's
 * loop counter inside the condition argument. */
#define ROI_SET_FEAT(cond) do {                              \
	unsigned _bit = (cond) ? idx : (TM_N + idx);             \
	lit[_bit >> 5] |= 1u << (_bit & 31);                     \
	idx++;                                                   \
} while (0)

/* raw 22x14 RGB565 ROI -> packed literal vector (TM_NWORDS uint32 words). */
static inline void roi_featurize(const uint16_t *roi, uint32_t *lit)
{
	uint8_t dsBr[COLOR_CELLS], dsR[COLOR_CELLS], dsG5[COLOR_CELLS], dsB[COLOR_CELLS];

	/* 2x2 block sums -> downsampled channels (running offsets -> no multiply) */
	unsigned o = 0, row0 = 0;
	for (int r = 0; r < DSH; r++) {
		unsigned row1 = row0 + ROI_COLS, cc = 0;
		for (int c = 0; c < DSW; c++) {
			int rs = 0, gs = 0, bs = 0;
			uint16_t p;
			p = roi[row0 + cc];     rs += (p >> 11) & 0x1F; gs += (p >> 5) & 0x3F; bs += p & 0x1F;
			p = roi[row0 + cc + 1]; rs += (p >> 11) & 0x1F; gs += (p >> 5) & 0x3F; bs += p & 0x1F;
			p = roi[row1 + cc];     rs += (p >> 11) & 0x1F; gs += (p >> 5) & 0x3F; bs += p & 0x1F;
			p = roi[row1 + cc + 1]; rs += (p >> 11) & 0x1F; gs += (p >> 5) & 0x3F; bs += p & 0x1F;
			dsBr[o] = (uint8_t)((rs + gs + bs) >> 2);
			dsR[o]  = (uint8_t)(rs >> 2);
			dsG5[o] = (uint8_t)(gs >> 3);     /* 6-bit green sum >>3 -> 5-bit scale */
			dsB[o]  = (uint8_t)(bs >> 2);
			o++; cc += 2;
		}
		row0 += 2 * ROI_COLS;
	}

	for (unsigned w = 0; w < TM_NWORDS; w++)
		lit[w] = 0;

	/* luma 8-neighbour LBP over the interior (order TL,T,TR,L,R,BL,B,BR) */
	unsigned idx = 0, base = DSW;
	for (int r = 1; r < DSH - 1; r++) {
		for (int c = 1; c < DSW - 1; c++) {
			unsigned b = base + c, up = b - DSW, dn = b + DSW;
			int ctr = dsBr[b];
			ROI_SET_FEAT(dsBr[up - 1] >= ctr);
			ROI_SET_FEAT(dsBr[up]     >= ctr);
			ROI_SET_FEAT(dsBr[up + 1] >= ctr);
			ROI_SET_FEAT(dsBr[b - 1]  >= ctr);
			ROI_SET_FEAT(dsBr[b + 1]  >= ctr);
			ROI_SET_FEAT(dsBr[dn - 1] >= ctr);
			ROI_SET_FEAT(dsBr[dn]     >= ctr);
			ROI_SET_FEAT(dsBr[dn + 1] >= ctr);
		}
		base += DSW;
	}

	/* colour bits over all cells, row-major: R>G, then R>B, then skin cue */
	for (unsigned k = 0; k < COLOR_CELLS; k++)
		ROI_SET_FEAT(dsR[k] > dsG5[k]);
	for (unsigned k = 0; k < COLOR_CELLS; k++)
		ROI_SET_FEAT(dsR[k] > dsB[k]);
	for (unsigned k = 0; k < COLOR_CELLS; k++)
		ROI_SET_FEAT(dsR[k] > dsG5[k] && dsG5[k] >= dsB[k] && (dsR[k] - dsB[k]) >= 2);
}

#undef ROI_SET_FEAT
#endif /* ROI_FEATURES_H */
