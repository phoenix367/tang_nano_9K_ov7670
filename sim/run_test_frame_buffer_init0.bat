SETLOCAL ENABLEEXTENSIONS

set iverilog="c:\iverilog\bin\iverilog.exe"
set iverilog_sim="c:\iverilog\bin\vvp.exe"
if defined tests_path (
    set src_dir=%tests_path%\..\src
) else (
    set src_dir=..\src
    set tests_path=.
)
set test_name=frame_buffer_test_init0

set test_bench_sources="%tests_path%\%test_name%.sv"^
 "%tests_path%\svlogger.sv"^
 "%src_dir%\functions.v"^
 "%src_dir%\arbiter.v"^
 "%src_dir%\timescale.v"^
 "%src_dir%\ov7670_default.sv"^
 "%src_dir%\gowin_rpll\memory_rpll.v"^
 "%src_dir%\gowin_sdpb\gowin_sdpb.v"^
 "%src_dir%\gowin_alu54\gowin_alu54.v"^
 "%src_dir%\fifo_top\fifo_cam_data.vo"^
 "%src_dir%\video_controller.sv"^
 "%src_dir%\fsms\FrameUploader.sv"^
 "C:\Gowin\Gowin_V1.9.9Beta-4\IDE\simlib\gw1n\prim_tsim.v"

set test_bench_name=%test_name%

echo Compiling test...
%iverilog% -g2012 -I %src_dir% -I %tests_path% -s main -s GSR -o %test_bench_name% %test_bench_sources%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%
echo Test compiled successfully
echo.

echo Start simulation...
%iverilog_sim% -n %test_bench_name%
EXIT /B %ERRORLEVEL%
