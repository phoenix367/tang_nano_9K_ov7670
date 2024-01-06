`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

module main();

    localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

    reg clk, reset_n;
    reg init_done = 1'b0;
    reg [7:0] pixel_data;
    wire cam_clk;
    wire queue_load_empty;
    wire [16:0] queue_data_out;
    wire queue_load_rd_en;

    reg v_sync, h_ref;
    integer frame_counter;

    string module_name;
    DataLogger #(.verbosity(LOG_LEVEL)) logger();

    localparam TARGET_IMAGE_WIDTH  = 640;
    localparam TARGET_IMAGE_HEIGHT = 480;

    // Camera timing parameters
    localparam CAM_PIXEL_CLK = 2;
    localparam CAM_HREF_CLK = TARGET_IMAGE_WIDTH * CAM_PIXEL_CLK;
    localparam CAM_LINE_CLK = 784 * CAM_PIXEL_CLK;
    localparam CAM_VSYNC_CLK = 3 * CAM_LINE_CLK;
    localparam CAM_HREF_DELAY_CLK = 20 * CAM_LINE_CLK;
    localparam CAM_FRAME_CLK = 510 * CAM_LINE_CLK;

    

    initial begin
        $sformat(module_name, "%m");

        logger.info(module_name, " << Starting the Simulation >>");

`ifdef ENABLE_DUMPVARS
        $dumpvars(0, main);
`endif

        // initially values
        clk = 0;
        init_done = 1'b0;
        v_sync = 1'b0;
        h_ref = 1'b0;

        // reset system
        reset_n = 1'b1; // negate reset
        #2;
        reset_n = 1'b0; // assert reset
        repeat(1) @(posedge clk);
        reset_n = 1'b1; // negate reset

        logger.info(module_name, "status: done reset");
        init_done = 1'b1;
    end

    always #18.519 clk=~clk;

    always #1200000 begin
        logger.error(module_name, "System hangs");
        `TEST_FAIL
    end

    wire [16:0] queue_data_in;
    wire queue_clk;
    wire queue_wr_en;

    FIFO_cam q_cam_data_in(
        .Data(queue_data_in), //input [16:0] Data
        .WrReset(~reset_n), //input WrReset
        .RdReset(~reset_n), //input RdReset
        .WrClk(queue_clk), //input WrClk
        .RdClk(queue_load_clk), //input RdClk
        .WrEn(queue_wr_en), //input WrEn
        .RdEn(queue_load_rd_en), //input RdEn
        .Q(queue_data_out), //output [16:0] Q
        .Empty(queue_load_empty), //output Empty
        .Full() //output Full
    );

    CameraHandler
    #(
        .LOG_LEVEL(LOG_LEVEL),
        .FRAME_WIDTH(TARGET_IMAGE_WIDTH),
        .FRAME_HEIGHT(TARGET_IMAGE_HEIGHT)
    )
    camera_handler
    (
        .PixelClk(cam_clk),
        .nRST(reset_n),
        .cam_vsync(v_sync),
        .cam_href(h_ref),
        .p_data(pixel_data),
        .init_done(init_done),

        .queue_clk(queue_clk),
        .queue_data(queue_data_in),
        .queue_wr_en(queue_wr_en)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            frame_counter = 0;
        end else if (init_done) begin
            if (frame_counter < CAM_VSYNC_CLK)
                v_sync <= #1 1'b1;
            else
                v_sync <= #1 1'b0;

            frame_counter <= #1 frame_counter + 1;
        end
    end
    
endmodule
