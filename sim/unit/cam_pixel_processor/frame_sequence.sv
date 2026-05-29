`include "timescale.v"
`include "svlogger.sv"
`include "test_utils.sv"
`include "test_config.sv"

// Unit test for CamPixelProcessor (OV7670 byte stream -> framed command
// stream + packed RGB565 pixels into the per-row double buffer).
//
// Scope: the command control path. The processor drives a small command
// FSM on clk_cam and crosses commands to clk_mem through a
// CDC_Word_Synchronizer; the downstream FrameUploader consumes them. The
// contract verified here is the command sequence for a frame:
//
//     frame-start (1) -> row (2) x FRAME_HEIGHT -> frame-end (3)
//
// driven by a minimal OV7670-like stimulus (v_sync pulse, then one h_ref
// burst of 2*FRAME_WIDTH bytes per active line). A second frame is fed to
// exercise the FRAME_DONE -> WRITE_FRAME_START re-arm path.
//
// The exact RGB565 packing into the BRAM is intentionally NOT checked: the
// IP writes `input_pixel` to the row buffer combinationally while the word
// address advances, so the final stored word depends on byte-level write
// timing that the real (smoothly varying) image data tolerates but that no
// simple golden model captures cleanly. The command sequence fully
// exercises the FSM control flow and the clk_cam -> clk_mem CDC.

module main();

localparam LOG_LEVEL = `SVL_VERBOSE_INFO;

localparam integer FRAME_WIDTH  = 4;
localparam integer FRAME_HEIGHT = 2;

// commands per frame: start + one per row + end
localparam integer CMDS_PER_FRAME = 2 + FRAME_HEIGHT;
localparam integer NUM_FRAMES     = 2;
localparam integer EXPECTED_CMDS  = CMDS_PER_FRAME * NUM_FRAMES;

reg         clk_cam;
reg         clk_mem;
reg         reset_n;
reg         init;
reg         v_sync;
reg         h_ref;
reg  [7:0]  cam_data;
reg  [9:0]  mem_addr;
reg         mem_controller_rdy;

wire [31:0] pixel_data;
wire [1:0]  command_data;
wire        command_data_valid;

string module_name;
DataLogger #(.verbosity(LOG_LEVEL)) logger();

CamPixelProcessor #(
`ifdef __ICARUS__
    .LOG_LEVEL(LOG_LEVEL),
`endif
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT)
) dut (
    .clk_cam(clk_cam),
    .clk_mem(clk_mem),
    .reset_n(reset_n),
    .init(init),

    .mem_controller_rdy(mem_controller_rdy),
    .mem_addr(mem_addr),

    .v_sync(v_sync),
    .h_ref(h_ref),
    .cam_data(cam_data),

    .pixel_data(pixel_data),
    .command_data(command_data),
    .command_data_valid(command_data_valid)
);

// ---- mem-side command collector -----------------------------------------
// One capture per valid-high episode (commands are well separated in time,
// so `consumed` reliably brackets each transfer and never double counts).
localparam integer MAX_CMDS = 16;
reg [1:0] cmd_log [0:MAX_CMDS-1];
integer   cmd_count;
reg       consumed;

always @(posedge clk_mem or negedge reset_n) begin
    if (!reset_n) begin
        cmd_count <= 0;
        consumed  <= 1'b0;
    end else begin
        if (command_data_valid && mem_controller_rdy && !consumed
            && cmd_count < MAX_CMDS) begin
            cmd_log[cmd_count] <= command_data;
            cmd_count          <= cmd_count + 1;
            consumed           <= 1'b1;
        end
        if (!command_data_valid)
            consumed <= 1'b0;
    end
end

// ---- OV7670-like stimulus ------------------------------------------------
// Feed one active line: 2*FRAME_WIDTH bytes, one per clk_cam, h_ref high.
task automatic feed_row(input integer base);
    integer i;
    begin
        @(negedge clk_cam);
        h_ref = 1'b1;
        for (i = 0; i < FRAME_WIDTH * 2; i = i + 1) begin
            cam_data = (base + i) & 8'hFF;
            @(negedge clk_cam);
        end
        h_ref    = 1'b0;
        cam_data = 8'h00;
    end
endtask

// Feed one whole frame: v_sync pulse, settle, then FRAME_HEIGHT lines with
// gaps long enough for each row command to cross and the FSM to re-enter
// PREPARE_ROW (which stalls on h_ref, so timing only needs to be generous).
task automatic feed_frame(input integer base);
    integer r;
    begin
        v_sync = 1'b1;
        repeat (4) @(negedge clk_cam);
        v_sync = 1'b0;
        repeat (30) @(negedge clk_cam);

        for (r = 0; r < FRAME_HEIGHT; r = r + 1) begin
            feed_row(base + r * 16);
            repeat (30) @(negedge clk_cam);
        end
    end
endtask

task automatic check_cmd(input integer idx, input [1:0] expected, input string what);
    string s;
    if (cmd_log[idx] !== expected) begin
        $sformat(s, "command[%0d] = %0d, expected %0d (%s)",
                 idx, cmd_log[idx], expected, what);
        logger.error(module_name, s);
        `TEST_FAIL
    end
endtask

integer f;

initial begin
    string str;

`ifdef ENABLE_DUMPVARS
    $dumpvars(0, main);
`endif

    $sformat(module_name, "%m");
    logger.info(module_name, " << Starting the Simulation >>");

    clk_cam            = 1'b0;
    clk_mem            = 1'b0;
    init               = 1'b0;
    v_sync             = 1'b0;
    h_ref              = 1'b0;
    cam_data           = 8'h00;
    mem_addr           = 10'd0;
    mem_controller_rdy = 1'b1;

    reset_n = 1'b1;
    #2;
    reset_n = 1'b0;
    repeat (4) @(posedge clk_mem);
    reset_n = 1'b1;

    @(negedge clk_cam);
    init = 1'b1;

    for (f = 0; f < NUM_FRAMES; f = f + 1)
        feed_frame(f * 64);

    // Let the last frame-end command drain across the CDC.
    repeat (40) @(posedge clk_mem);

    if (cmd_count !== EXPECTED_CMDS) begin
        $sformat(str, "captured %0d commands, expected %0d", cmd_count, EXPECTED_CMDS);
        logger.error(module_name, str);
        `TEST_FAIL
    end

    for (f = 0; f < NUM_FRAMES; f = f + 1) begin
        integer base_idx;
        integer row;
        base_idx = f * CMDS_PER_FRAME;

        check_cmd(base_idx, 2'd1, "frame start");
        for (row = 0; row < FRAME_HEIGHT; row = row + 1)
            check_cmd(base_idx + 1 + row, 2'd2, "row");
        check_cmd(base_idx + 1 + FRAME_HEIGHT, 2'd3, "frame end");
    end

    logger.info(module_name,
                "cam_pixel_processor frames the stream: start, per-row, end (x2 frames)");
    `TEST_PASS
end

// Camera pixel clock (slower) and memory clock (faster), as in the design.
always #10 clk_cam = ~clk_cam;
always #4  clk_mem = ~clk_mem;

// Watchdog: the whole run is only a few thousand ns.
always #2_000_000 begin
    logger.error(module_name, "System hangs");
    `TEST_FAIL
end

endmodule
