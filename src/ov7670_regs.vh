`ifndef OV7670_REGISTERS
`define OV7670_REGISTERS

`define OV7670_ADDR 8'h21 //< Default I2C address if unspecified


`define OV7670_REG_GAIN 8'h00               //< AGC gain bits 7:0 (9:8 in VREF)
`define OV7670_REG_BLUE 8'h01               //< AWB blue channel gain
`define OV7670_REG_RED 8'h02                //< AWB red channel gain
`define OV7670_REG_VREF 8'h03               //< Vert frame control bits
`define OV7670_REG_COM1 8'h04               //< Common control 1
`define OV7670_COM1_R656 8'h40              //< COM1 enable R656 format
`define OV7670_REG_BAVE 8'h05               //< U/B average level
`define OV7670_REG_GbAVE 8'h06              //< Y/Gb average level
`define OV7670_REG_AECHH 8'h07              //< Exposure value - AEC 15:10 bits
`define OV7670_REG_RAVE 8'h08               //< V/R average level
`define OV7670_REG_COM2 8'h09               //< Common control 2
`define OV7670_COM2_SSLEEP 8'h10            //< COM2 soft sleep mode
`define OV7670_REG_PID 8'h0A                //< Product ID MSB (read-only)
`define OV7670_REG_VER 8'h0B                //< Product ID LSB (read-only)
`define OV7670_REG_COM3 8'h0C               //< Common control 3
`define OV7670_COM3_SWAP 8'h40              //< COM3 output data MSB/LSB swap
`define OV7670_COM3_SCALEEN 8'h08           //< COM3 scale enable
`define OV7670_COM3_DCWEN 8'h04             //< COM3 DCW enable
`define OV7670_REG_COM4 8'h0D               //< Common control 4
`define OV7670_REG_COM5 8'h0E               //< Common control 5
`define OV7670_REG_COM6 8'h0F               //< Common control 6
`define OV7670_REG_AECH 8'h10               //< Exposure value 9:2
`define OV7670_REG_CLKRC 8'h11              //< Internal clock
`define OV7670_CLK_EXT 8'h40                //< CLKRC Use ext clock directly
`define OV7670_CLK_SCALE 8'h3F              //< CLKRC Int clock prescale mask
`define OV7670_REG_COM7 8'h12               //< Common control 7
`define OV7670_COM7_RESET 8'h80             //< COM7 SCCB register reset
`define OV7670_COM7_SIZE_MASK 8'h38         //< COM7 output size mask
`define OV7670_COM7_PIXEL_MASK 8'h05        //< COM7 output pixel format mask
`define OV7670_COM7_SIZE_VGA 8'h00          //< COM7 output size VGA
`define OV7670_COM7_SIZE_CIF 8'h20          //< COM7 output size CIF
`define OV7670_COM7_SIZE_QVGA 8'h10         //< COM7 output size QVGA
`define OV7670_COM7_SIZE_QCIF 8'h08         //< COM7 output size QCIF
`define OV7670_COM7_RGB 8'h04               //< COM7 pixel format RGB
`define OV7670_COM7_YUV 8'h00               //< COM7 pixel format YUV
`define OV7670_COM7_BAYER 8'h01             //< COM7 pixel format Bayer RAW
`define OV7670_COM7_PBAYER 8'h05            //< COM7 pixel fmt proc Bayer RAW
`define OV7670_COM7_COLORBAR 8'h02          //< COM7 color bar enable
`define OV7670_REG_COM8 8'h13               //< Common control 8
`define OV7670_COM8_FASTAEC 8'h80           //< COM8 Enable fast AGC/AEC algo,
`define OV7670_COM8_AECSTEP 8'h40           //< COM8 AEC step size unlimited
`define OV7670_COM8_BANDING 8'h20           //< COM8 Banding filter enable
`define OV7670_COM8_AGC 8'h04               //< COM8 AGC (auto gain) enable
`define OV7670_COM8_AWB 8'h02               //< COM8 AWB (auto white balance)
`define OV7670_COM8_AEC 8'h01               //< COM8 AEC (auto exposure) enable
`define OV7670_REG_COM9 8'h14               //< Common control 9 - max AGC value
`define OV7670_REG_COM10 8'h15              //< Common control 10
`define OV7670_COM10_HSYNC 8'h40            //< COM10 HREF changes to HSYNC
`define OV7670_COM10_PCLK_HB 8'h20          //< COM10 Suppress PCLK on hblank
`define OV7670_COM10_HREF_REV 8'h08         //< COM10 HREF reverse
`define OV7670_COM10_VS_EDGE 8'h04          //< COM10 VSYNC chg on PCLK rising
`define OV7670_COM10_VS_NEG 8'h02           //< COM10 VSYNC negative
`define OV7670_COM10_HS_NEG 8'h01           //< COM10 HSYNC negative
`define OV7670_REG_HSTART 8'h17             //< Horiz frame start high bits
`define OV7670_REG_HSTOP 8'h18              //< Horiz frame end high bits
`define OV7670_REG_VSTART 8'h19             //< Vert frame start high bits
`define OV7670_REG_VSTOP 8'h1A              //< Vert frame end high bits
`define OV7670_REG_PSHFT 8'h1B              //< Pixel delay select
`define OV7670_REG_MIDH 8'h1C               //< Manufacturer ID high byte
`define OV7670_REG_MIDL 8'h1D               //< Manufacturer ID low byte
`define OV7670_REG_MVFP 8'h1E               //< Mirror / vert-flip enable
`define OV7670_MVFP_MIRROR 8'h20            //< MVFP Mirror image
`define OV7670_MVFP_VFLIP 8'h10             //< MVFP Vertical flip
`define OV7670_REG_LAEC 8'h1F               //< Reserved
`define OV7670_REG_ADCCTR0 8'h20            //< ADC control
`define OV7670_REG_ADCCTR1 8'h21            //< Reserved
`define OV7670_REG_ADCCTR2 8'h22            //< Reserved
`define OV7670_REG_ADCCTR3 8'h23            //< Reserved
`define OV7670_REG_AEW 8'h24                //< AGC/AEC upper limit
`define OV7670_REG_AEB 8'h25                //< AGC/AEC lower limit
`define OV7670_REG_VPT 8'h26                //< AGC/AEC fast mode op region
`define OV7670_REG_BBIAS 8'h27              //< B channel signal output bias
`define OV7670_REG_GbBIAS 8'h28             //< Gb channel signal output bias
`define OV7670_REG_EXHCH 8'h2A              //< Dummy pixel insert MSB
`define OV7670_REG_EXHCL 8'h2B              //< Dummy pixel insert LSB
`define OV7670_REG_RBIAS 8'h2C              //< R channel signal output bias
`define OV7670_REG_ADVFL 8'h2D              //< Insert dummy lines MSB
`define OV7670_REG_ADVFH 8'h2E              //< Insert dummy lines LSB
`define OV7670_REG_YAVE 8'h2F               //< Y/G channel average value
`define OV7670_REG_HSYST 8'h30              //< HSYNC rising edge delay
`define OV7670_REG_HSYEN 8'h31              //< HSYNC falling edge delay
`define OV7670_REG_HREF 8'h32               //< HREF control
`define OV7670_REG_CHLF 8'h33               //< Array current control
`define OV7670_REG_ARBLM 8'h34              //< Array ref control - reserved
`define OV7670_REG_ADC 8'h37                //< ADC control - reserved
`define OV7670_REG_ACOM 8'h38               //< ADC & analog common - reserved
`define OV7670_REG_OFON 8'h39               //< ADC offset control - reserved
`define OV7670_REG_TSLB 8'h3A               //< Line buffer test option
`define OV7670_TSLB_NEG 8'h20               //< TSLB Negative image enable
`define OV7670_TSLB_YLAST 8'h04             //< TSLB UYVY or VYUY, see COM13
`define OV7670_TSLB_AOW 8'h01               //< TSLB Auto output window
`define OV7670_REG_COM11 8'h3B              //< Common control 11
`define OV7670_COM11_NIGHT 8'h80            //< COM11 Night mode
`define OV7670_COM11_NMFR 8'h60             //< COM11 Night mode frame rate mask
`define OV7670_COM11_HZAUTO 8'h10           //< COM11 Auto detect 50/60 Hz
`define OV7670_COM11_BAND 8'h08             //< COM11 Banding filter val select
`define OV7670_COM11_EXP 8'h02              //< COM11 Exposure timing control
`define OV7670_REG_COM12 8'h3C              //< Common control 12
`define OV7670_COM12_HREF 8'h80             //< COM12 Always has HREF
`define OV7670_REG_COM13 8'h3D              //< Common control 13
`define OV7670_COM13_GAMMA 8'h80            //< COM13 Gamma enable
`define OV7670_COM13_UVSAT 8'h40            //< COM13 UV saturation auto adj
`define OV7670_COM13_UVSWAP 8'h01           //< COM13 UV swap, use w TSLB[3]
`define OV7670_REG_COM14 8'h3E              //< Common control 14
`define OV7670_COM14_DCWEN 8'h10            //< COM14 DCW & scaling PCLK enable
`define OV7670_REG_EDGE 8'h3F               //< Edge enhancement adjustment
`define OV7670_REG_COM15 8'h40              //< Common control 15
`define OV7670_COM15_RMASK 8'hC0            //< COM15 Output range mask
`define OV7670_COM15_R10F0 8'h00            //< COM15 Output range 10 to F0
`define OV7670_COM15_R01FE 8'h80            //< COM15              01 to FE
`define OV7670_COM15_R00FF 8'hC0            //< COM15              00 to FF
`define OV7670_COM15_RGBMASK 8'h30          //< COM15 RGB 555/565 option mask
`define OV7670_COM15_RGB 8'h00              //< COM15 Normal RGB out
`define OV7670_COM15_RGB565 8'h10           //< COM15 RGB 565 output
`define OV7670_COM15_RGB555 8'h30           //< COM15 RGB 555 output
`define OV7670_REG_COM16 8'h41              //< Common control 16
`define OV7670_COM16_AWBGAIN 8'h08          //< COM16 AWB gain enable
`define OV7670_REG_COM17 8'h42              //< Common control 17
`define OV7670_COM17_AECWIN 8'hC0           //< COM17 AEC window must match COM4
`define OV7670_COM17_CBAR 8'h08             //< COM17 DSP Color bar enable
`define OV7670_REG_AWBC1 8'h43              //< Reserved
`define OV7670_REG_AWBC2 8'h44              //< Reserved
`define OV7670_REG_AWBC3 8'h45              //< Reserved
`define OV7670_REG_AWBC4 8'h46              //< Reserved
`define OV7670_REG_AWBC5 8'h47              //< Reserved
`define OV7670_REG_AWBC6 8'h48              //< Reserved
`define OV7670_REG_REG4B 8'h4B              //< UV average enable
`define OV7670_REG_DNSTH 8'h4C              //< De-noise strength
`define OV7670_REG_MTX1 8'h4F               //< Matrix coefficient 1
`define OV7670_REG_MTX2 8'h50               //< Matrix coefficient 2
`define OV7670_REG_MTX3 8'h51               //< Matrix coefficient 3
`define OV7670_REG_MTX4 8'h52               //< Matrix coefficient 4
`define OV7670_REG_MTX5 8'h53               //< Matrix coefficient 5
`define OV7670_REG_MTX6 8'h54               //< Matrix coefficient 6
`define OV7670_REG_BRIGHT 8'h55             //< Brightness control
`define OV7670_REG_CONTRAS 8'h56            //< Contrast control
`define OV7670_REG_CONTRAS_CENTER 8'h57     //< Contrast center
`define OV7670_REG_MTXS 8'h58               //< Matrix coefficient sign
`define OV7670_REG_LCC1 8'h62               //< Lens correction option 1
`define OV7670_REG_LCC2 8'h63               //< Lens correction option 2
`define OV7670_REG_LCC3 8'h64               //< Lens correction option 3
`define OV7670_REG_LCC4 8'h65               //< Lens correction option 4
`define OV7670_REG_LCC5 8'h66               //< Lens correction option 5
`define OV7670_REG_MANU 8'h67               //< Manual U value
`define OV7670_REG_MANV 8'h68               //< Manual V value
`define OV7670_REG_GFIX 8'h69               //< Fix gain control
`define OV7670_REG_GGAIN 8'h6A              //< G channel AWB gain
`define OV7670_REG_DBLV 8'h6B               //< PLL & regulator control
`define OV7670_REG_AWBCTR3 8'h6C            //< AWB control 3
`define OV7670_REG_AWBCTR2 8'h6D            //< AWB control 2
`define OV7670_REG_AWBCTR1 8'h6E            //< AWB control 1
`define OV7670_REG_AWBCTR0 8'h6F            //< AWB control 0
`define OV7670_REG_SCALING_XSC 8'h70        //< Test pattern X scaling
`define OV7670_REG_SCALING_YSC 8'h71        //< Test pattern Y scaling
`define OV7670_REG_SCALING_DCWCTR 8'h72     //< DCW control
`define OV7670_REG_SCALING_PCLK_DIV 8'h73   //< DSP scale control clock divide
`define OV7670_REG_REG74 8'h74              //< Digital gain control
`define OV7670_REG_REG76 8'h76              //< Pixel correction
`define OV7670_REG_SLOP 8'h7A               //< Gamma curve highest seg slope
`define OV7670_REG_GAM_BASE 8'h7B           //< Gamma register base (1 of 15)
`define OV7670_GAM_LEN 15                  //< Number of gamma registers
`define OV7670_R76_BLKPCOR 8'h80            //< REG76 black pixel corr enable
`define OV7670_R76_WHTPCOR 8'h40            //< REG76 white pixel corr enable
`define OV7670_REG_RGB444 8'h8C             //< RGB 444 control
`define OV7670_R444_ENABLE 8'h02            //< RGB444 enable
`define OV7670_R444_RGBX 8'h01              //< RGB444 word format
`define OV7670_REG_DM_LNL 8'h92             //< Dummy line LSB
`define OV7670_REG_LCC6 8'h94               //< Lens correction option 6
`define OV7670_REG_LCC7 8'h95               //< Lens correction option 7
`define OV7670_REG_HAECC1 8'h9F             //< Histogram-based AEC/AGC ctrl 1
`define OV7670_REG_HAECC2 8'hA0             //< Histogram-based AEC/AGC ctrl 2
`define OV7670_REG_SCALING_PCLK_DELAY 8'hA2 //< Scaling pixel clock delay
`define OV7670_REG_BD50MAX 8'hA5            //< 50 Hz banding step limit
`define OV7670_REG_HAECC3 8'hA6             //< Histogram-based AEC/AGC ctrl 3
`define OV7670_REG_HAECC4 8'hA7             //< Histogram-based AEC/AGC ctrl 4
`define OV7670_REG_HAECC5 8'hA8             //< Histogram-based AEC/AGC ctrl 5
`define OV7670_REG_HAECC6 8'hA9             //< Histogram-based AEC/AGC ctrl 6
`define OV7670_REG_HAECC7 8'hAA             //< Histogram-based AEC/AGC ctrl 7
`define OV7670_REG_BD60MAX 8'hAB            //< 60 Hz banding step limit
`define OV7670_REG_ABLC1 8'hB1              //< ABLC enable
`define OV7670_REG_THL_ST 8'hB3             //< ABLC target
`define OV7670_REG_SATCTR 8'hC9             //< Saturation control

`endif /* OV7670_REGISTERS */
