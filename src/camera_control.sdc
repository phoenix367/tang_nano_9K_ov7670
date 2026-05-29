//Copyright (C)2014-2024 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//GOWIN Version: 1.9.9 Beta-4
//Created Time: 2024-01-13 12:35:09
create_clock -name base -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]
create_clock -name video_clock -period 37.037 -waveform {0 18.518} [get_ports {video_clk_i}]
create_generated_clock -name memory_clock -source [get_ports {sys_clk}] -master_clock base -multiply_by 5 [get_nets {memory_clk}]
create_generated_clock -name lcd_clock -source [get_ports {sys_clk}] -master_clock base -divide_by 2 -multiply_by 1 [get_ports {LCD_CLK}]

// fb_clk = memory_clock / 2, generated inside the PSRAM controller's
// clkdiv block. Without an explicit declaration the analyzer treats it
// as an unconstrained generated clock and falls back to the master
// period for the setup budget.
create_generated_clock -name fb_clk -source [get_nets {memory_clk}] -master_clock memory_clock -divide_by 2 [get_pins {VGA_timing_inst/frame_buffer/clkdiv/CLKOUT}]

// memory_clock -> fb_clk crosses a 2:1 frequency ratio. The default
// setup check uses one launch period (7.407 ns), but the data has two
// launch periods (= one capture period, 14.815 ns) before the next
// fb_clk rising edge captures it. Without the multicycle the ~770
// memory_clock -> fb_clk endpoints inside the HyperRAM IP appear as
// false setup violations. The matching -hold 1 keeps the hold check at
// the immediate edge so we don't accidentally relax it.
set_multicycle_path 2 -setup -from [get_clocks {memory_clock}] -to [get_clocks {fb_clk}]
set_multicycle_path 1 -hold  -from [get_clocks {memory_clock}] -to [get_clocks {fb_clk}]

set_clock_groups -exclusive -group [get_clocks {base}] -group [get_clocks {memory_clock}]
set_false_path -from [get_clocks {video_clock}] -to [get_clocks {memory_clock}]
set_false_path -from [get_clocks {lcd_clock}] -to [get_clocks {video_clock}]
set_false_path -from [get_pins {VGA_timing_inst/frame_buffer/clkdiv/CLKOUT}] -to [get_clocks {video_clock}]

// Cam-output FIFO (q_cam_data_out) is async: WrClk = fb_clk
// (FrameDownloader emit side), RdClk = lcd_clock (LCD consumer).
// Gray-coded pointers — STA reports hold violations on the write
// pointer compare network without an explicit exclusion.
set_clock_groups -asynchronous -group [get_clocks {fb_clk}] -group [get_clocks {lcd_clock}]

// CamPixelProcessor's CDC_Word_Synchronizer crosses video_clock (camera
// PCLK) <-> fb_clk (memory-side). The existing pin-form false_path
// already covers fb_clk -> video_clock; this declares the same async
// relationship on the named clocks so it stays symmetric and survives
// any future refactor that renames the clkdiv pin.
set_clock_groups -asynchronous -group [get_clocks {fb_clk}] -group [get_clocks {video_clock}]

// The HyperRAM IP leaves 3 iserdes -> u_psram_init/calib_0_s0 hold
// violations (worst -0.252 ns) that can't be cleaned from user SDC:
// the synthesis-mangled cell name visible in the timing report isn't
// reachable via get_pins / get_cells (Gowin errors with TA2003 on a
// wildcard, silently no-ops on the literal hierarchy). Calibration
// runs once at power-up before any traffic, so these paths are not
// silicon-real; clearing them would require an IP version that ships
// its own SDC carve-out.

report_high_fanout_nets -max_nets 10
