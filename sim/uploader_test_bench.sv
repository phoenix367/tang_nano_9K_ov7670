`include "timescale.v"
`include "svlogger.sv"

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

DataLogger #(.verbosity(LOG_LEVEL)) logger();
reg clk, reset_n;

endmodule
