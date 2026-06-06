/*
 * demo_mcu_apps / c_hello
 *
 * The same idea as osd_hello, but in C instead of assembly: after the bootloader
 * hands it control (via the common crt0.S, which sets up a stack and zeroes
 * .bss), it clears + enables the OSD and writes "Hello from C!" centered on it,
 * then returns -- crt0 jumps back to the bootloader so the host can load another
 * overlay without a reset.
 *
 * Device access is the shared demo_mcu_apps/common/serv_io.h. Built with the
 * RISC-V C toolchain; linked at 0x1000 (serv_soc/overlay_c.ld).
 */
#include "serv_io.h"

#define MSG "Hello from C!"            /* 13 chars */

void main(void)
{
	osd_clear_enable();
	osd_at(8, (OSD_COLS - 13) / 2);     /* row 8, centered */
	osd_puts(MSG);
}
