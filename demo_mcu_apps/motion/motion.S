/*
 * demo_mcu_apps / motion  --  background-subtraction motion detector (assembly)
 *
 * Hand-written reference implementation. The C twin `demo_mcu_apps/motion_c` is
 * functionally identical and runs at the same FPS (the monitor loop is grab-bound
 * -- each iteration waits for a fresh camera frame -- so compiler vs hand-asm
 * overhead is hidden). Keep both as an asm-vs-C comparison. (An earlier belief
 * that gcc miscompiled this loop turned out to be the 0xE0 register only
 * round-tripping its low byte, masking a status field -- not a codegen bug.)
 *
 * What it does (runs on the SERV soft core as a Wishbone master):
 *   1. grab a camera frame into ch1 PSRAM,
 *   2. sample NS pixels spread across the frame and SAVE them as a background
 *      model in a FREE region of PSRAM (BG_BASE, well above the frame),
 *   3. loop forever: grab a new frame, re-sample, compare each sample's RGB565
 *      brightness to the saved background; >= MINCNT samples changed by more than
 *      THRESH means movement. Every BG_PERIOD frames the background is REFRESHED
 *      in place from the current frame, so it adapts over time.
 *
 * It also measures its own PROCESSING FPS -- frames compared per second -- using
 * the 1 Hz uptime counter (0xF1/0xF2) as the time base (no RTC needed): it counts
 * monitor-loop iterations between uptime-second ticks.
 *
 * Reports on the OSD ("Motion detect", "FPS: NN", "Movement: YES/NO",
 * "changed: 0xNN", "bg refresh: 0xNN") and writes the measured FPS to the
 * heartbeat reg (0xE0, low byte) for the host to read race-free.
 *
 * Parks (monitors forever); reset the MCU (0xE2) to return to the bootloader.
 * Linked at 0x1000 (serv_soc/overlay.ld). Uses no stack: every subroutine is a
 * leaf (none call another), so ra is never nested.
 *
 * Register/access conventions:
 *   s0 = EXT base (0x40000000); the low 16 bits of an address select the register.
 *   Subroutines use only t0-t3 / a1-a3 (and read s0); they never write s1..s11,
 *   so the monitor loop's state survives across calls.
 */
#define OSD_CTRL  0xFB
#define OSD_ADDR  0xFC
#define OSD_DATA  0xFD
#define GRAB      0xF3         /* w:1=grab 2=read 3=write; r:b0=busy b1=calib */
#define GRAB_ALO  0xF4
#define GRAB_AHI  0xF5
#define GRAB_DHI  0xF6
#define HEARTBEAT 0xE0
#define UPTIME_HI 0xF1         /* read latches the 16-bit uptime; returns hi byte */
#define UPTIME_LO 0xF2         /* returns the latched low byte (seconds & 0xFF) */

#define NS        48           /* sample points across the frame */
#define SSTEP     6352         /* address step between samples (397 bursts * 16) */
#define THRESH    12           /* per-sample brightness-diff threshold */
#define MINCNT    4            /* >= this many changed samples -> movement */
#define BG_MASK   31           /* refresh every (BG_MASK+1)=32 frames; power-of-2-1 */

#define HDR_CUR   (8*60 + 23)  /* "Motion detect" */
#define FPS_CUR   (9*60 + 23)  /* "FPS: NN" */
#define MOVE_CUR  (10*60 + 23) /* "Movement: ..." */
#define CHG_CUR   (11*60 + 23) /* "changed: 0xNN" */
#define BGR_CUR   (12*60 + 23) /* "bg refresh: 0xNN" */
#define BGR_DIG   (12*60 + 37) /* the two hex digits after "bg refresh: 0x" */

	.globl _start
_start:
	lui  s0, 0x40000           /* s0 = EXT base */

	/* clear + enable the OSD, wait out the blank sweep */
	li   t1, 3
	sb   t1, OSD_CTRL(s0)
	li   t2, 512
1:	addi t2, t2, -1
	bnez t2, 1b

	/* wait until ch1 PSRAM has calibrated (0xF3 bit1) */
calwait:
	lbu  t1, GRAB(s0)
	andi t1, t1, 2
	beqz t1, calwait

	/* static labels */
	li   a1, HDR_CUR
	sh   a1, OSD_ADDR(s0)
	la   a1, msg_hdr
	jal  puts
	li   a1, BGR_CUR
	sh   a1, OSD_ADDR(s0)
	la   a1, msg_bgr
	jal  puts

	/* ---- build the background model from the first frame -> free PSRAM ---- */
	jal  grab
	li   s5, 0                 /* i */
	li   s6, 0                 /* frame sample address */
	lui  s7, 0x80              /* bg address (BG_BASE = 0x80000) */
bgbuild:
	mv   a1, s6
	jal  psram_rd              /* a2 = sample pixel */
	mv   a1, s7
	jal  psram_wr              /* bg[s7] = a2 */
	li   t0, SSTEP
	add  s6, s6, t0
	addi s7, s7, 16
	addi s5, s5, 1
	li   t0, NS
	blt  s5, t0, bgbuild

	/* monitor-loop persistent state */
	li   s1, 0                 /* frame counter */
	li   s8, 0                 /* fps_count: iterations in the current second */
	li   s9, 0                 /* fps: last measured frames/second */
	lbu  t0, UPTIME_HI(s0)     /* latch the uptime, then read the low byte */
	lbu  s2, UPTIME_LO(s0)     /* s2 = last_sec (seconds & 0xFF) */

	/* ---- monitor loop ---- */
mloop:
	jal  grab

	/* refresh = (frame != 0) && ((frame & BG_MASK) == 0) */
	li   s3, 0
	beqz s1, no_refresh
	andi t0, s1, BG_MASK
	bnez t0, no_refresh
	li   s3, 1
no_refresh:

	li   s4, 0                 /* changed = 0 */
	li   s5, 0                 /* i */
	li   s6, 0                 /* frame sample address */
	lui  s7, 0x80              /* bg address */
samp:
	mv   a1, s6
	jal  psram_rd              /* a2 = current pixel */
	jal  bright                /* a3 = brightness(current) */
	mv   s10, a3               /* save current brightness */
	mv   s11, a2               /* save current pixel (for a refresh write) */
	mv   a1, s7
	jal  psram_rd              /* a2 = background pixel */
	jal  bright                /* a3 = brightness(background) */
	sub  t0, s10, a3           /* brightness diff */
	bgez t0, 1f
	sub  t0, zero, t0          /* abs */
1:	li   t1, THRESH
	bge  t1, t0, 2f            /* diff <= THRESH -> not changed */
	addi s4, s4, 1             /* changed++ */
2:	beqz s3, 3f                /* refresh this frame? fold current into bg */
	mv   a1, s7
	mv   a2, s11
	jal  psram_wr
3:	li   t0, SSTEP
	add  s6, s6, t0
	addi s7, s7, 16
	addi s5, s5, 1
	li   t0, NS
	blt  s5, t0, samp

	/* "Movement: YES/NO"  (moved in t4: used by the branch before any call) */
	li   t0, MINCNT
	slt  t1, s4, t0
	xori t4, t1, 1             /* t4 = (changed >= MINCNT) */
	li   a1, MOVE_CUR
	sh   a1, OSD_ADDR(s0)
	beqz t4, move_no
	la   a1, msg_yes
	jal  puts
	j    move_done
move_no:
	la   a1, msg_no
	jal  puts
move_done:

	/* "changed: 0xNN" */
	li   a1, CHG_CUR
	sh   a1, OSD_ADDR(s0)
	la   a1, msg_chg
	jal  puts
	srli a1, s4, 4
	jal  hexnib
	sb   a1, OSD_DATA(s0)
	mv   a1, s4
	jal  hexnib
	sb   a1, OSD_DATA(s0)

	/* on a refresh frame, update "bg refresh" (count = frame >> BG_SHIFT) */
	beqz s3, no_bgdisp
	li   a1, BGR_DIG
	sh   a1, OSD_ADDR(s0)
	srli t5, s1, 5             /* refresh count */
	srli a1, t5, 4
	jal  hexnib
	sb   a1, OSD_DATA(s0)
	mv   a1, t5
	jal  hexnib
	sb   a1, OSD_DATA(s0)
no_bgdisp:

	/* ---- processing FPS: count iterations between 1 Hz uptime ticks ---- */
	lbu  t0, UPTIME_HI(s0)     /* latch the uptime */
	lbu  t1, UPTIME_LO(s0)     /* t1 = current second (low byte) */
	beq  t1, s2, fps_same
	mv   s9, s8                /* a second elapsed: fps = iterations counted */
	li   s8, 1                 /* start counting the current iteration */
	mv   s2, t1                /* last_sec = current */
	li   a1, FPS_CUR           /* repaint "FPS: NN" */
	sh   a1, OSD_ADDR(s0)
	la   a1, msg_fps
	jal  puts
	mv   a1, s9
	jal  dec2
	j    fps_done
fps_same:
	addi s8, s8, 1             /* fps_count++ */
fps_done:
	sh   s9, HEARTBEAT(s0)     /* heartbeat low byte = measured FPS */

	addi s1, s1, 1             /* frame++ */
	j    mloop

/* ---------------- leaf subroutines (use t0-t3 / a1-a3, read s0) ------------- */

/* grab a camera frame into ch1; wait for completion */
grab:
	li   t0, 1
	sb   t0, GRAB(s0)
1:	lbu  t0, GRAB(s0)
	andi t0, t0, 1
	bnez t0, 1b
	ret

/* read ch1 burst word0 high half at address a1 -> a2 */
psram_rd:
	sh   a1, GRAB_ALO(s0)
	srli t0, a1, 16
	andi t0, t0, 0x1F
	sb   t0, GRAB_AHI(s0)
	li   t0, 2
	sb   t0, GRAB(s0)          /* read-trigger */
1:	lbu  t0, GRAB(s0)
	andi t0, t0, 1
	bnez t0, 1b
	lhu  a2, GRAB_DHI(s0)
	ret

/* write value a2 to every word of the ch1 burst at address a1 */
psram_wr:
	sh   a2, GRAB_DHI(s0)
	sh   a1, GRAB_ALO(s0)
	srli t0, a1, 16
	andi t0, t0, 0x1F
	sb   t0, GRAB_AHI(s0)
	li   t0, 3                 /* write-trigger */
	sb   t0, GRAB(s0)
1:	lbu  t0, GRAB(s0)
	andi t0, t0, 1
	bnez t0, 1b
	ret

/* RGB565 pixel a2 -> rough brightness (R + G + B) in a3 */
bright:
	srli t0, a2, 11
	andi t0, t0, 0x1F          /* R */
	srli t1, a2, 5
	andi t1, t1, 0x3F          /* G */
	andi t2, a2, 0x1F          /* B */
	add  a3, t0, t1
	add  a3, a3, t2
	ret

/* print a1 as two decimal digits to the OSD (value assumed < 100). No divide:
 * tens via repeated subtraction. Uses t1, t2, a1. */
dec2:
	li   t1, 0                 /* tens */
1:	li   t2, 10
	blt  a1, t2, 2f
	sub  a1, a1, t2
	addi t1, t1, 1
	j    1b
2:	addi t1, t1, '0'
	sb   t1, OSD_DATA(s0)
	addi a1, a1, '0'
	sb   a1, OSD_DATA(s0)
	ret

/* low nibble of a1 -> ASCII hex digit in a1 */
hexnib:
	andi a1, a1, 0xF
	li   t0, 10
	blt  a1, t0, 1f
	addi a1, a1, 'A' - 10
	ret
1:	addi a1, a1, '0'
	ret

/* print the NUL-terminated string at a1 to the OSD (cursor auto-increments) */
puts:
	lbu  t0, 0(a1)
	beqz t0, 1f
	sb   t0, OSD_DATA(s0)
	addi a1, a1, 1
	j    puts
1:	ret

	.data
msg_hdr:
	.asciz "Motion detect"
msg_fps:
	.asciz "FPS: "
msg_bgr:
	.asciz "bg refresh: 0x00"
msg_yes:
	.asciz "Movement: YES"
msg_no:
	.asciz "Movement: NO "
msg_chg:
	.asciz "changed: 0x"
