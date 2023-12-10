//Copyright (C)2014-2023 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//GOWIN Version: V1.9.9 Beta-4
//Part Number: GW1NR-LV9QN88PC6/I5
//Device: GW1NR-9
//Device Version: C
//Created Time: Sun Dec 10 16:33:50 2023

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

    Gowin_ALU54 your_instance_name(
        .dout(dout_o), //output [21:0] dout
        .caso(caso_o), //output [54:0] caso
        .a(a_i), //input [20:0] a
        .b(b_i), //input [10:0] b
        .ce(ce_i), //input ce
        .clk(clk_i), //input clk
        .reset(reset_i) //input reset
    );

//--------Copy end-------------------
