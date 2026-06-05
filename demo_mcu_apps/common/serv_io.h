/*
 * serv_io.h -- shared device-register access for SERV C overlays.
 *
 * The SERV soft core reaches the camera's Wishbone registers through the EXT
 * window (base 0x40000000; the low 16 bits are the register number). serv_wb_cdc
 * resolves the non-word-aligned registers from the byte address + access width,
 * so a volatile uint8 store emits the `sb` and a uint16 store the `sh` that the
 * byte-lane CDC expects -- the same accesses the asm demos make by hand.
 *
 * Helpers here are `static inline` so a tiny overlay pulls in only what it uses
 * (no .data/.bss, no libc). Register map: doc/modbus_server.md.
 */
#ifndef SERV_IO_H
#define SERV_IO_H

#include <stdint.h>

#define EXT 0x40000000u

/* RW scratch / co-master "heartbeat" register -- the host reads it over Modbus as
 * a race-free side channel (a single 16-bit access, unlike the OSD cursor). */
#define HEARTBEAT (*(volatile uint16_t *)(EXT + 0xE0u))

/* ---- OSD text overlay ---- */
#define OSD_CTRL (*(volatile uint8_t  *)(EXT + 0xFBu))  /* bit0=enable, bit1=clear */
#define OSD_ADDR (*(volatile uint16_t *)(EXT + 0xFCu))  /* cursor = row*OSD_COLS + col */
#define OSD_DATA (*(volatile uint8_t  *)(EXT + 0xFDu))  /* char at cursor; auto-increments */
#define OSD_COLS 60
#define OSD_BLOCK 0x96u                                 /* full-block glyph */

/* ---- channel-1 PSRAM via the wb_grab read/write port ---- */
#define GRAB     (*(volatile uint8_t  *)(EXT + 0xF3u))  /* w:2=read 3=write; r:b0=busy b1=calib */
#define GRAB_ALO (*(volatile uint16_t *)(EXT + 0xF4u))  /* burst address [15:0] */
#define GRAB_AHI (*(volatile uint8_t  *)(EXT + 0xF5u))  /* burst address [20:16] */
#define GRAB_DHI (*(volatile uint16_t *)(EXT + 0xF6u))  /* write/read data, high half */

/* Busy-wait; the volatile counter keeps the compiler from optimizing it away. */
static inline void delay(int n)
{
	for (volatile int i = 0; i < n; i++)
		;
}

/* ---- OSD helpers ---- */
static inline void osd_clear_enable(void)
{
	OSD_CTRL = 0x03;                /* clear sweep + enable */
	delay(2000);                    /* let the hardware blank sweep finish */
}

static inline void osd_at(unsigned row, unsigned col)
{
	OSD_ADDR = (uint16_t)(row * OSD_COLS + col);
}

static inline void osd_putc(char c)
{
	OSD_DATA = (uint8_t)c;
}

static inline void osd_puts(const char *s)
{
	while (*s)
		OSD_DATA = (uint8_t)*s++;   /* cursor auto-increments per char */
}

/* ---- ch1 PSRAM helpers ----
 * The write port drives ALL words of the burst with the same value, so reading
 * back word0's high half (GRAB_DHI) recovers exactly what was written. We use the
 * high half because 0xF7 (the low half) is byte-addressed in SERV's view. */
static inline void psram_wait_idle(void)
{
	while (GRAB & 0x01u)            /* bit0 = busy */
		;
}

static inline int psram_calibrated(void)
{
	return (GRAB & 0x02u) != 0;     /* bit1 = ch1 calibrated */
}

/* Capture a fresh camera frame into ch1 PSRAM, laid out contiguously from
 * address 0 (640x480 RGB565: burst k = 16 pixels starting at pixel 16*k). */
static inline void psram_grab_frame(void)
{
	GRAB = 1;                       /* arm a grab */
	psram_wait_idle();
}

static inline void psram_write16(uint32_t addr, uint16_t val)
{
	GRAB_DHI = val;                 /* wr_data[31:16] = val */
	GRAB_ALO = (uint16_t)addr;
	GRAB_AHI = (uint8_t)((addr >> 16) & 0x1Fu);
	GRAB = 3;                       /* write-trigger */
	psram_wait_idle();
}

static inline uint16_t psram_read16(uint32_t addr)
{
	GRAB_ALO = (uint16_t)addr;
	GRAB_AHI = (uint8_t)((addr >> 16) & 0x1Fu);
	GRAB = 2;                       /* read-trigger */
	psram_wait_idle();
	return GRAB_DHI;                /* ch1 word[31:16] */
}

#endif /* SERV_IO_H */
