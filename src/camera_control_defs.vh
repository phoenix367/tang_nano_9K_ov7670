`ifndef WRAP_SIM
`define WRAP_SIM(x) \
    `ifdef __ICARUS__ \
        x \
    `endif
`endif
