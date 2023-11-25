`include "timescale.v"
`include "svlogger.sv"

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

reg clk, reset_n;
wire cam_clk;
wire LCD_CLK;
wire LCD_DE;
wire LCD_HYNC;
reg [4:0] LCD_R;
reg [5:0] LCD_G;
reg [4:0] LCD_B;

DataLogger #(.verbosity(LOG_LEVEL)) logger();

localparam TARGET_IMAGE_WIDTH = 481;
localparam TARGET_IMAGE_HEIGHT = 273;

// Camera timing parameters
localparam CAM_PIXEL_CLK = 2;
localparam CAM_HREF_CLK = 640 * CAM_PIXEL_CLK;
localparam CAM_LINE_CLK = 784 * CAM_PIXEL_CLK;
localparam CAM_VSYNC_CLK = 3 * CAM_LINE_CLK;
localparam CAM_HREF_DELAY_CLK = 20 * CAM_LINE_CLK;
localparam CAM_FRAME_CLK = 510 * CAM_LINE_CLK;

int fd;
int cam_clock_counter;
int num_frames;
string module_name;

initial begin
    $sformat(module_name, "%m");

    logger.info(module_name, " << Starting the Simulation >>");
    // initially values
    clk = 0;

    // reset system
    reset_n = 1'b1; // negate reset
    #2;
    reset_n = 1'b0; // assert reset
    repeat(1) @(posedge clk);
    reset_n = 1'b1; // negate reset

    logger.info(module_name, "status: done reset");

    @(posedge clk);
end

always #18.519 clk=~clk;
assign cam_clk = clk;

wire cam_vsync;
wire cam_href;

always @(posedge cam_clk) begin
    if (cam_clock_counter < CAM_FRAME_CLK)
        cam_clock_counter <= #1 cam_clock_counter + 1;
    else
        cam_clock_counter <= #1 0;
end

assign cam_vsync = (cam_clock_counter < CAM_VSYNC_CLK) ? 1'b1 : 1'b0;
assign cam_href = (cam_clock_counter >= CAM_HREF_DELAY_CLK && 
                   ((cam_clock_counter - CAM_HREF_DELAY_CLK) % CAM_LINE_CLK) < CAM_HREF_CLK) ? 1'b1 : 1'b0;

wire memory_clk;
wire pll_lock;

wire [1:0] psram_ck;
wire [1:0] psram_ck_n;
wire [1:0] rwds;
wire [1:0] psram_reset_n;
wire [15:0] psram_dq;
wire [1:0] psram_cs_n;

wire error_sig;

SDRAM_rPLL sdram_clock(.reset(~reset_n), .clkin(clk), .clkout(memory_clk), .lock(pll_lock));
VGA_timing #(.LOG_LEVEL(LOG_LEVEL)) vga_timing(
    .PixelClk(clk),
    .nRST(reset_n),
    .memory_clk(memory_clk),
    .pll_lock(pll_lock),
    .cam_vsync(cam_vsync),
    .href(cam_href),
    .p_data(8'h0),
    .debug_led(error_sig),

    .O_psram_ck(psram_ck),
    .O_psram_ck_n(psram_ck_n),
    .IO_psram_rwds(rwds),
    .O_psram_reset_n(psram_reset_n),
    .IO_psram_dq(psram_dq),
    .O_psram_cs_n(psram_cs_n)
);

generate
    genvar o;
    for(o = 0; o < 2; o = o + 1'b1) begin:memory_models
       W955D8MKY #(.MODULE_NAME(), .LOG_LEVEL(LOG_LEVEL)) psram_model(
          .resetb           (psram_reset_n[o]),
          .clk              (psram_ck[o]),
          .clk_n            (psram_ck_n[o]),
          .ceb              (psram_cs_n[o]),
          .adq              (psram_dq[((o+1)*8-1)-:8]),
          .rwds             (rwds[o]),
          .VCC              (VCC),
          .VSS              (1'b0) 
        );
      end
endgenerate

always @(error_sig)
    if (!error_sig) begin
        logger.error(module_name, "Memory Error occurred");
        $fatal;
    end

`ifdef __ICARUS__
initial begin
    //$dumpvars();
end
`endif

endmodule
