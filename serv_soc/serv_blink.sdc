// 27 MHz system clock (single clock domain for the SERV bring-up).
create_clock -name sys_clk -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]
