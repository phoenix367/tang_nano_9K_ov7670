set iverilog="c:\iverilog\bin\iverilog.exe"
set iverilog_sim="c:\iverilog\bin\vvp.exe"
set src_dir="..\src"
set test_bench_sources="video_test_bench.sv"^
 "psram_model.sv"^
 "..\src\functions.v"^
 "..\src\arbiter.v"^
 "..\src\timescale.v"^
 "..\src\ov7670_default.sv"^
 "..\src\VGA_timing.v"^
 "..\src\gowin_dpb\img_row_biffer.v"^
 "..\src\gowin_rpll\memory_rpll.v"^
 "..\src\fifo_top\fifo_cam_data.vo"^
 "..\src\video_controller.sv"^
 "..\src\psram_memory_interface_hs_2ch\psram_memory_interface_hs_2ch.vo"^
 "C:\Gowin\Gowin_V1.9.9Beta-4\IDE\simlib\gw1n\prim_tsim.v"

set test_bench_name="video_test_bench"

%iverilog% -g2012 -I %src_dir% -s main -s GSR -o %test_bench_name% %test_bench_sources%

%iverilog_sim% -v %test_bench_name%
