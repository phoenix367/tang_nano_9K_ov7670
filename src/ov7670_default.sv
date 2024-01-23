`include "timescale.v"
`include "ov7670_regs.vh"
`include "camera_control_defs.vh"

module ov7670_default(
    input [7:0] addr_i,
    output reg [15:0] dout
) /*synthesis syn_romstyle="distributed_rom"*/;

    function reg [15:0] make_setting_value(input reg [7:0] reg_addr, input reg [7:0] reg_value);
        make_setting_value = { reg_addr, reg_value };
    endfunction

    always @(addr_i) begin
        case(addr_i) 
/*
            0:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM7, `OV7670_COM7_RESET);//16'h12_80; //reset
            1:  dout <= `WRAP_SIM(#1) make_setting_value(8'hFF, 8'hF0);//16'hFF_F0; //delay
            2:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM7, `OV7670_COM7_RGB);//16'h12_04; // COM7,     set RGB color output
            3:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_RGB444, 8'h00);//16'h11_80; // CLKRC     internal PLL matches input clock
            4:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM15, `OV7670_COM15_RGB565 | `OV7670_COM15_R00FF);//16'h0C_00; // COM3,     default settings
            5:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_TSLB, `OV7670_TSLB_YLAST);//16'h3E_00; // COM14,    no scaling, normal pclock
            6:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_CLKRC, 8'h03);//16'h04_00; // COM1,     disable CCIR656
            7:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_DBLV, 8'h00);//16'h40_10; //COM15,     RGB565, full output range
            8:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE, 8'h1C);//16'h3a_04; //TSLB       set correct output data sequence (magic)
            9:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 1, 8'h38);//16'h14_18; //COM9       MAX AGC value x4
            10: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 2, 8'h3C);//16'h4F_40; //MTX1       all of these are magical matrix coefficients
            11: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 3, 8'h55);//16'h50_34; //MTX2
            12: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 4, 8'h68);//16'h51_0C; //MTX3
            13: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 5, 8'h76);//16'h52_17; //MTX4
            14: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 6, 8'h80);//16'h53_29; //MTX5
            15: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 7, 8'h88);//16'h54_40; //MTX6
            16: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 8, 8'h8F);//16'h58_1E; //MTXS
            17: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 9, 8'h96);//16'h3D_C0; //COM13      sets gamma enable, does not preserve reserved bits, may be wrong?
            18: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 10, 8'hA3);//16'h17_14; //HSTART     start high 8 bits
            19: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 11, 8'hAF);//16'h18_02; //HSTOP      stop high 8 bits //these kill the odd colored line
            20: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 12, 8'hC4);//16'h32_80; //HREF       edge offset
            21: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 13, 8'hD7);//16'h19_03; //VSTART     start high 8 bits
            22: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAM_BASE + 14, 8'hE8);//16'h1A_7B; //VSTOP      stop high 8 bits
            23: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM8,
                                                         `OV7670_COM8_FASTAEC | `OV7670_COM8_AECSTEP | `OV7670_COM8_BANDING);//16'h03_0A; //VREF       vsync edge offset
            24: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GAIN, 8'h00);//16'h0F_41; //COM6       reset timings
            25: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_COM2_SSLEEP, 8'h00);//`WRAP_SIM(#1) 16'h1E_00; //MVFP       disable mirror / flip //might have magic value of 03
            26: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM4, 8'h00);//16'h33_0B; //CHLF       //magic value from the internet
            27: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM9, 8'h20);//16'h3C_78; //COM12      no HREF when VSYNC low
            28: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_BD50MAX, 8'h05);//16'h69_00; //GFIX       fix gain control
            29: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_BD60MAX, 8'h07);//16'h74_00; //REG74      Digital gain control
            30: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AEW, 8'h75);//16'hB0_84; //RSVD       magic value from the internet *required* for good color
            31: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AEB, 8'h63);//16'hB1_0c; //ABLC1
            32: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_VPT, 8'hA5);//16'hB2_0e; //RSVD       more magic internet values
            33: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC1, 8'h78);//16'hB3_80; //THL_ST
            //begin mystery scaling numbers
            34: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC2, 8'h68);//16'h70_3a;
            35: dout <= `WRAP_SIM(#1) 16'h71_B5;//16'h71_35;  // Test pattern
            36: dout <= `WRAP_SIM(#1) 16'h6B_CA;//16'h6B_4A;  // PLL
            37: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC3, 8'hDF);//16'h73_f0;
            38: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC4, 8'hDF);//16'ha2_02;
            //gamma curve values
            39: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC5, 8'hF0);//16'h7a_20;
            40: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC6, 8'h90);//16'h7b_10;
            41: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC7, 8'h94);//16'h7c_1e;
            42: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM8, `OV7670_COM8_FASTAEC | `OV7670_COM8_AECSTEP |
                              `OV7670_COM8_BANDING | `OV7670_COM8_AGC |
                              `OV7670_COM8_AEC);//16'h7d_35;
            43: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM5, 8'h61);//16'h7e_5a;
            44: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM6, 8'h4B);//16'h7f_69;
            45: dout <= `WRAP_SIM(#1) make_setting_value(8'h16, 8'h02);//16'h80_76;
            46: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_MVFP, 8'h07);//16'h81_80;
            47: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_ADCCTR1, 8'h02);//16'h82_88;
            48: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_ADCCTR2, 8'h91);//16'h83_8f;
            49: dout <= `WRAP_SIM(#1) make_setting_value(8'h29, 8'h07);//16'h84_96;
            50: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_CHLF, 8'h0B);//16'h85_a3;
            51: dout <= `WRAP_SIM(#1) make_setting_value(8'h35, 8'h0B);//16'h86_af;
            52: dout <= `WRAP_SIM(#1) 16'h87_c4;
            53: dout <= `WRAP_SIM(#1) 16'h88_d7;
            54: dout <= `WRAP_SIM(#1) 16'h89_e8;
            //AGC and AEC
            55: dout <= `WRAP_SIM(#1) 16'h13_e0; //COM8, disable AGC / AEC
            56: dout <= `WRAP_SIM(#1) 16'h00_00; //set gain reg to 0 for AGC
            57: dout <= `WRAP_SIM(#1) 16'h10_00; //set ARCJ reg to 0
            58: dout <= `WRAP_SIM(#1) 16'h0d_40; //magic reserved bit for COM4
            59: dout <= `WRAP_SIM(#1) 16'h14_18; //COM9, 4x gain + magic bit
            60: dout <= `WRAP_SIM(#1) 16'ha5_05; // BD50MAX
            61: dout <= `WRAP_SIM(#1) 16'hab_07; //DB60MAX
            62: dout <= `WRAP_SIM(#1) 16'h24_95; //AGC upper limit
            63: dout <= `WRAP_SIM(#1) 16'h25_33; //AGC lower limit
            64: dout <= `WRAP_SIM(#1) 16'h26_e3; //AGC/AEC fast mode op region
            65: dout <= `WRAP_SIM(#1) 16'h9f_78; //HAECC1
            66: dout <= `WRAP_SIM(#1) 16'ha0_68; //HAECC2
            67: dout <= `WRAP_SIM(#1) 16'ha1_03; //magic
            68: dout <= `WRAP_SIM(#1) 16'ha6_d8; //HAECC3
            69: dout <= `WRAP_SIM(#1) 16'ha7_d8; //HAECC4
            70: dout <= `WRAP_SIM(#1) 16'ha8_f0; //HAECC5
            71: dout <= `WRAP_SIM(#1) 16'ha9_90; //HAECC6
            72: dout <= `WRAP_SIM(#1) 16'haa_94; //HAECC7
            73: dout <= `WRAP_SIM(#1) 16'h13_e5; //COM8, enable AGC / AEC
*/

            0:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM7, `OV7670_COM7_RESET);       //reset
            1:  dout <= 16'hFF_F0; //delay
            2:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM7, `OV7670_COM7_RGB);         // COM7,     set RGB color output
            3:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_CLKRC, 8'h01);                   // CLKRC     internal PLL divide input clock by 2
            4:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM3, 8'h00);                    // COM3,     default settings
            5:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM14, 8'h00);                   // COM14,    no scaling, normal pclock
            6:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM1, 8'h00);                    // COM1,     disable CCIR656
            7:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM15, 
                                                         `OV7670_COM15_R00FF | `OV7670_COM15_RGB565); //COM15,     RGB565, full output range
            8:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_TSLB, `OV7670_TSLB_YLAST);       //TSLB       set correct output data sequence (magic)
            9:  dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM9, 8'h18);                    //COM9       MAX AGC value x4
            10: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_MTX1, 8'h80);                    //MTX1       all of these are magical matrix coefficients
            11: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_MTX2, 8'h80);                    //MTX2
            12: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_MTX3, 8'h00);                    //MTX3
            13: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_MTX4, 8'h22);                    //MTX4
            14: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_MTX5, 8'h5E);                    //MTX5
            15: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_MTX6, 8'h80);                    //MTX6
            16: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_MTXS, 8'h9E);                    //MTXS
            17: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM13, 
                                                         `OV7670_COM13_GAMMA | `OV7670_COM13_UVSAT);  //COM13      sets gamma enable, does not preserve reserved bits, may be wrong?
            18: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HSTART, 8'h14);                  //HSTART     start high 8 bits
            19: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HSTOP, 8'h02);                   //HSTOP      stop high 8 bits //these kill the odd colored line
            20: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_RGB444, 8'h00);                  //RGB444     turn off RGB444 mode
            21: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_VSTART, 8'h03);                  //VSTART     start high 8 bits
            22: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_VSTOP, 8'h7B);                   //VSTOP      stop high 8 bits
            23: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_VREF, 8'h0A);                    //VREF       vsync edge offset
            24: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM6, 8'h41);                    //COM6       reset timings
            25: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_MVFP, 8'h00);                    //MVFP       disable mirror / flip //might have magic value of 03
            26: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_CHLF, 8'h0B);                    //CHLF       //magic value from the internet
            27: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM12, 8'h78);                   //COM12      no HREF when VSYNC low
            28: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GFIX, 8'h00);                    //GFIX       fix gain control
            29: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_REG74, 8'h00);                   //REG74      Digital gain control
            30: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_ABLC1, 8'h0C);                   //ABLC1
            31: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_THL_ST, 8'h80);                  //THL_ST
            32: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_DBLV, 8'h4A);                    //DBLV       multiply clock by 4
            33: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_GGAIN, 8'h00);                   //GGAIN
            34: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HREF, 8'h80);                    //HREF       edge offset
            35: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC1, 8'h78);//16'hB3_80; //THL_ST
            //begin mystery scaling numbers
            36: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC2, 8'h68);//16'h70_3a;
            37: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC3, 8'hDF);//16'h73_f0;
            38: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC4, 8'hDF);//16'ha2_02;
            //gamma curve values
            39: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC5, 8'hF0);//16'h7a_20;
            40: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC6, 8'h90);//16'h7b_10;
            41: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_HAECC7, 8'h94);//16'h7c_1e;
            //40: dout <= `WRAP_SIM(#1) 16'h71_B5;//16'h71_35;  // Test pattern
            42: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_COM8, 
                              `OV7670_COM8_FASTAEC | `OV7670_COM8_AECSTEP |
                              `OV7670_COM8_BANDING | `OV7670_COM8_AGC |
                              `OV7670_COM8_AEC);
            43: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_RSVD_B0, 8'h84);                 //RSVD       magic value from the internet *required* for good color
            44: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_RSVD_B2, 8'h0E);                 //RSVD       more magic internet values
            45: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AWBC1, 8'h14);
            46: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AWBC2, 8'hF0);
            47: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AWBC3, 8'h34);
            48: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AWBC4, 8'h58);
            49: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AWBC5, 8'h28);
            50: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AWBC6, 8'h3A);
            51: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_LCC3, 8'h04);
            52: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_LCC4, 8'h20);
            53: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_LCC5, 8'h05);
            54: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_LCC6, 8'h04);
            55: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_LCC7, 8'h08);
            56: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AWBCTR3, 8'h0A);
            57: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AWBCTR2, 8'h55);
            58: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_BD50MAX, 8'h05);//16'h69_00; //GFIX       fix gain control
            59: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_BD60MAX, 8'h07);//16'h74_00; //REG74      Digital gain control
            60: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AEW, 8'h75);//16'hB0_84; //RSVD       magic value from the internet *required* for good color
            61: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_AEB, 8'h63);//16'hB1_0c; //ABLC1
            62: dout <= `WRAP_SIM(#1) make_setting_value(`OV7670_REG_VPT, 8'hA5);//16'hB2_0e; //RSVD       more magic internet values

            default: dout <= `WRAP_SIM(#1) 16'hFF_FF;         //mark end of ROM
        endcase
    end
endmodule
