set iverilog="c:\iverilog\bin\iverilog.exe"
set iverilog_sim="c:\iverilog\bin\vvp.exe"
set src_dir="..\src"

set test_bench_sources_baseline="tst_bench_top.v"^
 "..\src\timescale.v"^
 "..\src\i2c_master_defines.v"^
 "..\src\i2c_master_bit_ctrl.v"^
 "..\src\i2c_master_byte_ctrl.v"^
 "..\src\i2c_master.v"^
 "wb_master_model.v"^
 "i2c_slave_model.sv"

set test_bench_name_baseline="test_bench_baseline"

%iverilog% -g2012 -I %src_dir% -o %test_bench_name_baseline% %test_bench_sources_baseline%

%iverilog_sim% %test_bench_name_baseline%
