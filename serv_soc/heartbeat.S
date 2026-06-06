/*
 * SERV Phase-2 heartbeat firmware.
 * Writes a monotonically increasing counter to the heartbeat register so the
 * host can read it over Modbus and confirm SERV is alive on the Wishbone bus.
 * HB_ADDR's low 16 bits are the Modbus register address (0x00E0); the high bits
 * place it in SERV's external (peripheral) bus region. Word store -> sel=1111,
 * so the be-adapter takes dat[15:0] regardless of byte lane.
 */
#ifndef HB_ADDR
#define HB_ADDR 0x400000E0
#endif
#ifndef HB_DELAY
#define HB_DELAY 0x400
#endif

	.globl _start
_start:
	lui  a0, %hi(HB_ADDR)
	addi a0, a0, %lo(HB_ADDR)   /* a0 = heartbeat register address */
	li   t0, 0                  /* counter */
loop:
	sw   t0, 0(a0)              /* heartbeat <- counter */
	addi t0, t0, 1
	li   t1, HB_DELAY
delay:
	addi t1, t1, -1
	bnez t1, delay
	j    loop
