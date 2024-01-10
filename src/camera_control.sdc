//Copyright (C)2014-2024 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//GOWIN Version: 1.9.9 Beta-4
//Created Time: 2024-01-10 02:05:56
create_clock -name base -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]
create_clock -name video_clock -period 37.037 -waveform {0 18.518} [get_ports {video_clk_i}]
create_generated_clock -name memory_clock -source [get_ports {sys_clk}] -master_clock base -multiply_by 5 [get_nets {memory_clk}]
create_generated_clock -name lcd_clock -source [get_ports {sys_clk}] -master_clock base -divide_by 3 -multiply_by 1 [get_ports {LCD_CLK}]
set_clock_groups -exclusive -group [get_clocks {base}] -group [get_clocks {memory_clock}]
set_false_path -from [get_clocks {video_clock}] -to [get_clocks {memory_clock}] 
set_false_path -from [get_clocks {lcd_clock}] -to [get_clocks {video_clock}] 
set_false_path -from [get_pins {VGA_timing_inst/frame_buffer/clkdiv/CLKOUT}] -to [get_clocks {video_clock}] 
report_high_fanout_nets -max_nets 10
