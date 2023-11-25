//Copyright (C)2014-2023 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//GOWIN Version: V1.9.9 Beta-4
//Part Number: GW1NR-LV9QN88PC6/I5
//Device: GW1NR-9
//Device Version: C
//Created Time: Mon Oct 23 00:58:22 2023

module Gowin_DQCE (clkout, clkin, ce);

output clkout;
input clkin;
input ce;

DQCE dqce_inst (
    .CLKOUT(clkout),
    .CLKIN(clkin),
    .CE(ce)
);

endmodule //Gowin_DQCE
