/*
 * demo_mcu_apps / psram_test
 *
 * Runs on the SERV soft core as a Wishbone master. It exercises the channel-1
 * PSRAM through the wb_grab write/read port:
 *
 *   1. write a pseudo-random 16-bit sequence into NREG PSRAM bursts (one value
 *      per burst, via 0xF6 = the high half of the 32-bit burst word),
 *   2. read each burst back and compare against the regenerated sequence,
 *   3. print "PSRAM test: PASS" or "PSRAM test: FAIL" on the OSD,
 *
 * then RETURN CONTROL TO THE BOOTLOADER so the host can load another overlay.
 *
 * PSRAM access (all via the EXT window; serv_wb_cdc resolves the non-word-aligned
 * registers from the byte address + byte-enables):
 *   0xF3  write 2 = read-trigger, 3 = write-trigger; read bit0 = busy, bit1 = calib
 *   0xF4  ch1 burst address [15:0]      0xF5  ch1 burst address [20:16]
 *   0xF6  write = wr_data[31:16]; read = ch1 word[31:16]   (we use the high half)
 * The write port drives ALL words of the burst with the same value, so reading
 * back word0's high half recovers exactly what we wrote.
 *
 * Linked at 0x1000 (serv_soc/overlay.ld); the bootloader is at 0x0000.
 */
#define EXT       0x40000000   /* SERV ext window; low 16 bits = device register */
#define OSD_CTRL  0xFB         /* bit0 = enable, bit1 = clear */
#define OSD_ADDR  0xFC         /* char-cell cursor (row*60 + col) */
#define OSD_DATA  0xFD         /* char at cursor; auto-increments */
#define GRAB      0xF3         /* trigger / status */
#define GRAB_ALO  0xF4         /* burst address [15:0] */
#define GRAB_AHI  0xF5         /* burst address [20:16] */
#define GRAB_DHI  0xF6         /* write/read data, high half */
#define NREG      32           /* number of PSRAM bursts to test */
#define SEED      0xACE1       /* pseudo-random generator seed */
#define CURSOR    502          /* row 8, col 22 -> centers "PSRAM test: PASS" (16 ch) */
#define BOOTLOADER 0x0000

	.globl _start
_start:
	li   a0, EXT
	li   s5, 0xFFFF             /* 16-bit mask for the generator */

	/* clear + enable the OSD, wait out the blank sweep */
	li   t0, 3
	sb   t0, OSD_CTRL(a0)
	li   t2, 512
1:	addi t2, t2, -1
	bnez t2, 1b

	/* wait until ch1 PSRAM has calibrated (0xF3 bit1) before touching it */
calwait:
	lbu  t0, GRAB(a0)
	andi t0, t0, 2
	beqz t0, calwait

	/* ---- write pass: NREG bursts, value = next(gen) at addr = i*16 ---- */
	li   s0, 0                  /* i */
	li   s1, NREG
	li   s2, SEED               /* generator state */
	li   s3, 0                  /* burst address */
wloop:
	beq  s0, s1, wdone
	jal  gen                    /* s2 <- next pseudo-random 16-bit value */
	sh   s2, GRAB_DHI(a0)       /* wr_data[31:16] = value */
	sh   s3, GRAB_ALO(a0)       /* address [15:0] */
	sb   zero, GRAB_AHI(a0)     /* address [20:16] = 0 */
	li   t0, 3
	sb   t0, GRAB(a0)           /* write-trigger */
	jal  wait_idle
	addi s0, s0, 1
	addi s3, s3, 16
	j    wloop
wdone:

	/* ---- read pass: regenerate the sequence and compare ---- */
	li   s0, 0
	li   s2, SEED
	li   s3, 0
	li   s4, 0                  /* fail flag */
rloop:
	beq  s0, s1, rdone
	jal  gen
	sh   s3, GRAB_ALO(a0)
	sb   zero, GRAB_AHI(a0)
	li   t0, 2
	sb   t0, GRAB(a0)           /* read-trigger */
	jal  wait_idle
	lhu  t1, GRAB_DHI(a0)       /* ch1 word[31:16] read back */
	beq  t1, s2, rok
	li   s4, 1                  /* mismatch -> FAIL */
rok:
	addi s0, s0, 1
	addi s3, s3, 16
	j    rloop
rdone:

	/* ---- print the verdict ---- */
	li   t0, CURSOR
	sh   t0, OSD_ADDR(a0)
	la   t1, msg_pass
	beqz s4, prnt
	la   t1, msg_fail
prnt:
	lbu  t0, 0(t1)
	beqz t0, done
	sb   t0, OSD_DATA(a0)
	addi t1, t1, 1
	j    prnt
done:
	li   t0, BOOTLOADER
	jr   t0                     /* hand control back to the bootloader */

/* s2 <- (s2*5 + 0x1B) & 0xFFFF  -- a small reproducible LCG (no mul: x5 = x + x<<2) */
gen:
	slli t0, s2, 2
	add  s2, s2, t0
	addi s2, s2, 0x1B
	and  s2, s2, s5
	ret

/* spin until the ch1 engine clears busy (0xF3 bit0) */
wait_idle:
	lbu  t0, GRAB(a0)
	andi t0, t0, 1
	bnez t0, wait_idle
	ret

	.data
msg_pass:
	.asciz "PSRAM test: PASS"
msg_fail:
	.asciz "PSRAM test: FAIL"
