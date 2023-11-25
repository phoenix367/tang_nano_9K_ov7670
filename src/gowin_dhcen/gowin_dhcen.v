//Copyright (C)2014-2023 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//GOWIN Version: V1.9.9 Beta-4
//Part Number: GW1NR-LV9QN88PC6/I5
//Device: GW1NR-9
//Device Version: C
//Created Time: Sat Oct 21 01:31:26 2023

module Gowin_DHCEN (clkout, clkin, ce);

output clkout;
input clkin;
input ce;

DHCEN dhcen_inst (
    .CLKOUT(clkout),
    .CLKIN(clkin),
    .CE(ce)
);

endmodule //Gowin_DHCEN
