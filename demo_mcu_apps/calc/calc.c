/*
 * demo_mcu_apps / calc  --  host-driven floating-point calculator (C)
 *
 * A console calculator that talks to the host and exercises IEEE-754 single-
 * precision floating point on the SERV soft core. SERV is RV32I (no FPU), so the
 * arithmetic is libgcc soft-float -- which is why this overlay needs the larger
 * (16 KB) MCU RAM build.
 *
 * Protocol (host -> MCU, over the bootloader mailbox, 5 x 16-bit words per command):
 *     word0 = opcode
 *     word1,2 = operand A  (IEEE-754 float bits: low half, high half)
 *     word3,4 = operand B  (ditto; ignored by unary ops)
 * The MCU computes, shows "= <result>" on the OSD (the console), writes the 32-bit
 * result as 4 raw bytes to a fixed OSD cell run (so the host can read it back
 * exactly), and bumps the heartbeat (0xE0 low byte) as a done signal.
 *
 * Ops: + - * /, sqrt (Newton-Raphson), 1/x, and x^n (integer exponent). Parks;
 * reset the MCU (0xE2) to stop it. Built with libgcc (soft-float + soft integer
 * divide for the decimal formatting). Uses the shared common/ runtime.
 */
#include <stdint.h>
#include "serv_io.h"

enum { OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_SQRT, OP_RECIP, OP_POW };

/* result bytes: 4 raw IEEE-754 bytes the host reads back (row 16, cols 0..3) */
#define RES_ROW 16
#define RES_COL 0

static float u2f(uint32_t u) { union { uint32_t u; float f; } x; x.u = u; return x.f; }
static uint32_t f2u(float f) { union { uint32_t u; float f; } x; x.f = f; return x.u; }

/* sqrt by Newton-Raphson (uses soft-float * and /) */
static float my_sqrt(float v)
{
	if (v <= 0.0f)
		return 0.0f;
	float g = v;
	for (int i = 0; i < 20; i++)
		g = 0.5f * (g + v / g);
	return g;
}

/* x raised to an integer power (repeated multiply; negative -> reciprocal) */
static float my_pow(float a, int n)
{
	int neg = n < 0;
	if (neg)
		n = -n;
	float r = 1.0f;
	while (n-- > 0)
		r *= a;
	return neg ? 1.0f / r : r;
}

static void put_uint(unsigned v)        /* decimal (libgcc soft divide) */
{
	char buf[12];
	int n = 0;
	if (v == 0u) { osd_putc('0'); return; }
	while (v) { buf[n++] = (char)('0' + (v % 10u)); v /= 10u; }
	while (n--)
		osd_putc(buf[n]);
}

static void put_float(float v)          /* sign, integer part, '.', 4 fraction digits */
{
	if (v < 0.0f) { osd_putc('-'); v = -v; }
	unsigned ip = (unsigned)v;
	put_uint(ip);
	osd_putc('.');
	float frac = v - (float)ip;
	for (int i = 0; i < 4; i++) {
		frac *= 10.0f;
		unsigned d = (unsigned)frac;
		osd_putc((char)('0' + d));
		frac -= (float)d;
	}
}

void main(void)
{
	osd_clear_enable();
	osd_at(6, 20); osd_puts("Calculator (C float)");
	osd_at(8, 18); osd_puts("host: op, a, b  ->  result");

	for (unsigned seq = 0; ; ) {
		/* read one 5-word command from the host */
		unsigned op = mailbox_get();
		uint32_t alo = mailbox_get(), ahi = mailbox_get();
		uint32_t blo = mailbox_get(), bhi = mailbox_get();
		float a = u2f((ahi << 16) | alo);
		float b = u2f((bhi << 16) | blo);

		float r;
		switch (op) {
		case OP_ADD:   r = a + b;            break;
		case OP_SUB:   r = a - b;            break;
		case OP_MUL:   r = a * b;            break;
		case OP_DIV:   r = a / b;            break;
		case OP_SQRT:  r = my_sqrt(a);       break;
		case OP_RECIP: r = 1.0f / a;         break;
		case OP_POW:   r = my_pow(a, (int)b); break;
		default:       r = 0.0f;             break;
		}

		/* console line: "= <result>" (pad to clear any previous longer value) */
		osd_at(10, 20);
		osd_puts("= ");
		put_float(r);
		osd_puts("            ");

		/* raw 32-bit result for the host to read back exactly */
		uint32_t rb = f2u(r);
		osd_at(RES_ROW, RES_COL);
		osd_putc((char)(rb & 0xFF));
		osd_putc((char)((rb >> 8) & 0xFF));
		osd_putc((char)((rb >> 16) & 0xFF));
		osd_putc((char)((rb >> 24) & 0xFF));

		/* done signal: bump the heartbeat (host waits for it to leave its sentinel) */
		seq++;
		HEARTBEAT = (uint16_t)(seq & 0xFFu);
	}
}
