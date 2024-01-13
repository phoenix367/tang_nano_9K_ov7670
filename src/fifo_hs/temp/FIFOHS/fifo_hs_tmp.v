//Copyright (C)2014-2023 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//GOWIN Version: V1.9.9 Beta-4
//Part Number: GW1NR-LV9QN88PC6/I5
//Device: GW1NR-9
//Device Version: C
//Created Time: Thu Jan 11 03:20:56 2024

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	FIFO_HS_Top your_instance_name(
		.Data(Data_i), //input [8:0] Data
		.WrReset(WrReset_i), //input WrReset
		.RdReset(RdReset_i), //input RdReset
		.WrClk(WrClk_i), //input WrClk
		.RdClk(RdClk_i), //input RdClk
		.WrEn(WrEn_i), //input WrEn
		.RdEn(RdEn_i), //input RdEn
		.Q(Q_o), //output [8:0] Q
		.Empty(Empty_o), //output Empty
		.Full(Full_o) //output Full
	);

//--------Copy end-------------------
