`include "timescale.v"
`include "camera_control_defs.vh"

`ifdef __ICARUS__
`include "svlogger.sv"
`endif

`define max2(v1, v2) ((v1) > (v2) ? (v1) : (v2))

`default_nettype wire

module VideoController
#(
`ifdef __ICARUS__
    parameter MODULE_NAME = "",
    parameter LOG_LEVEL = `SVL_VERBOSE_INFO,
`endif

    parameter int MEMORY_BURST = 32,
    parameter int INPUT_IMAGE_WIDTH = 640,
    parameter int INPUT_IMAGE_HEIGHT = 480,
    parameter int OUTPUT_IMAGE_WIDTH = 480,
    parameter int OUTPUT_IMAGE_HEIGHT = 272,
    parameter MEMORY_INITIAL_DELAY = 'd152,
    parameter int ENABLE_OUTPUT_RESIZE = 0,
    parameter int DEBUG_BUFFER_INDEX = -1
)
(
      input clk,
      input rst_n,
      input init_done,
      input [31:0] rd_data,
      input rd_data_valid,
      output reg [20:0] addr,
      output reg cmd,
      output reg cmd_en,
      output reg [31:0] wr_data,
      output reg [3:0] data_mask,
      output error,

      // Load queue interface
      output load_clk_o,
      output load_read_rdy,
      output [9:0] load_mem_addr,
      input load_command_valid,
      input [31:0] load_pixel_data,
      input [1:0] load_command_data,

      // Store queue interface
      output store_clk_o,
      output store_wr_en,
      input store_queue_full,
      output [16:0] store_queue_data
);

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

//localparam  IDLE                = 6'b000001;
localparam  START_WAITE         = 6'b000010;
localparam  WRITE_ALL_ADDR      = 6'b000100;
localparam  WRITE_WAITE         = 6'b001000;
localparam  READ_ALL_ADDR       = 6'b010000;
localparam  CYC_DONE_WAITE      = 6'b100000;
localparam  ADDR_RANGE          = 10'h1FF;//15'h7FFF;

localparam NUM_FRAMES = 3;
localparam NUM_DEVICES = 4;  // Max number of devices have access to shared frame buffer data

localparam FRAME_UPLOADER_IDX = 0;
localparam FRAME_DOWNLOADER_IDX = 1;
localparam DATA_WRITER_IDX = 2;
localparam DATA_READER_IDX = 3;

localparam FRAME_COUNTER_WIDTH = $clog2(`max2(INPUT_IMAGE_WIDTH, INPUT_IMAGE_HEIGHT) + 1);

typedef enum {
    UPLOADING_IDLE,
    UPLOADING_START_WAITE,
    UPLOADING_LOCK_BUFFER,
    UPLOADING_FIND_BUFFER,
    UPLOADING_SELECT_BUFFER,
    UPLOADING_START_PROCESS_FRAME,
    UPLOADING_FRAME_DONE_WAIT,
    UPLOADING_RELEASE_BUFFER,
    UPLOADING_RELEASE_BUFFER_WAIT
} UploadingStates;

typedef enum {
    DOWNLOADING_IDLE,
    DOWNLOADING_START_WAITE,
    DOWNLOADING_LOCK_BUFFER,
    DOWNLOADING_FIND_BUFFER,
    DOWNLOADING_SELECT_BUFFER,
    DOWNLOADING_START_PROCESS_FRAME,
    DOWNLOADING_FRAME_DONE_WAIT,
    DOWNLOADING_RELEASE_BUFFER,
    DOWNLOADING_RELEASE_BUFFER_WAIT
} DownloadingStates;

typedef enum {
    FRAME_PROCESSING_START,
    FRAME_PROCESSING_WRITE_ROW,
    FRAME_PROCESSING_DONE
} FrameProcessingStates;

UploadingStates uploading_state;
UploadingStates uploading_next_state;

DownloadingStates downloading_state;
DownloadingStates downloading_next_state;

reg [7:0] uploading_start_cnt;

reg producer_req;  // Flag to request buffer metadata access for frame data uploader
reg consumer_req;  // Flag to reqeust buffer metadata access for frame data receiver
wire data_write_req;
wire data_read_req;

reg [1:0] upload_buffer_idx;
reg [1:0] download_buffer_idx;

reg [FRAME_COUNTER_WIDTH - 1:0] upload_row_counter;
reg [FRAME_COUNTER_WIDTH - 1:0] upload_col_counter;

reg [20:0] write_base_addr;
reg [20:0] read_base_addr;

wire [NUM_DEVICES - 1:0] shared_req;
wire [NUM_DEVICES - 1:0] shared_grant;
wire mem_wr_en;
wire mem_rd_en;
wire uploading_finished;
wire downloading_finished;

reg start_uploading;
reg start_downloading;

reg buffer_read_rdy = 1'b0;
reg buffer_read_finalize = 1'b0;
reg buffer_write_rdy = 1'b0;
reg buffer_write_finalize = 1'b0;

assign shared_req = {data_read_req, data_write_req, consumer_req, producer_req};
assign store_clk_o = clk;

assign cmd = (mem_wr_en) ? 1'b1 : 1'b0;
assign cmd_en = (mem_wr_en | mem_rd_en) ? 1'b1 : 1'b0;

`ifdef __ICARUS__
always @(mem_wr_en or mem_rd_en)
    if (mem_wr_en == 1'b1 && mem_rd_en == 1'b1) begin
        logger.critical(module_name, "Invalid read and write signals");
    end
`endif

wire [20:0] read_addr_o;
wire [20:0] write_addr_o;

always_comb begin
    if (cmd_en) begin
        if (cmd)
            addr = write_addr_o;
        else
            addr = read_addr_o;
    end else
        addr = 'd0;
end

FrameUploader #(
    .FRAME_WIDTH(INPUT_IMAGE_WIDTH), 
    .FRAME_HEIGHT(INPUT_IMAGE_HEIGHT),
    .MEMORY_BURST(MEMORY_BURST)
`ifdef __ICARUS__
    , .LOG_LEVEL(LOG_LEVEL)
`endif
) frame_uploader(.clk(clk), .reset_n(rst_n),
                 .start(start_uploading), 
                 .command_data_valid(load_command_valid),
                 .pixel_data(load_pixel_data), 
                 .write_ack(shared_grant[DATA_WRITER_IDX]),
                 .read_rdy(load_read_rdy),
                 .mem_load_clk(load_clk_o),
                 .write_rq(data_write_req),
                 .write_addr(write_addr_o), 
                 .mem_wr_en(mem_wr_en),
                 .write_data(wr_data), 
                 .upload_done(uploading_finished), 
                 .base_addr(write_base_addr),
                 .pixel_addr(load_mem_addr),
                 .command_data(load_command_data)
                );

FrameDownloader #(
    .FRAME_WIDTH(OUTPUT_IMAGE_WIDTH), 
    .FRAME_HEIGHT(OUTPUT_IMAGE_HEIGHT),
    .ORIG_FRAME_WIDTH(INPUT_IMAGE_WIDTH), 
    .ORIG_FRAME_HEIGHT(INPUT_IMAGE_HEIGHT),
    .MEMORY_BURST(MEMORY_BURST),
    .ENABLE_RESIZE(ENABLE_OUTPUT_RESIZE)
`ifdef __ICARUS__
    , .LOG_LEVEL(LOG_LEVEL)
`endif
) frame_downloader(
    .clk(clk),
    .reset_n(rst_n),
    .start(start_downloading),
    .queue_full(store_queue_full),
    .read_ack(shared_grant[DATA_READER_IDX]),
    .base_addr(read_base_addr),
    .read_data(rd_data),
    .rd_data_valid(rd_data_valid),
    
    .queue_data_o(store_queue_data),
    .wr_en(store_wr_en),
    .read_rq(data_read_req),
    .read_addr(read_addr_o),
    .mem_rd_en(mem_rd_en),
    .download_done(downloading_finished)
);

arbiter #(.width(NUM_DEVICES), .select_width($clog2(NUM_DEVICES))) shared_arbiter(
    .enable(1'b1), .select(), .valid(),
    .req(shared_req), .grant(shared_grant),
    .reset(~rst_n), .clock(clk)
);

wire buffer_data_valid;
wire [1:0] buffer_id_data;

BufferController
#(
`ifdef __ICARUS__
    .LOG_LEVEL(LOG_LEVEL)
`endif
)
buffer_controller
(
    .clk(clk),
    .reset_n(rst_n),
    .write_rq_rdy(buffer_write_rdy),
    .finalize_wr(buffer_write_finalize),
    .read_rq_rdy(buffer_read_rdy),
    .finalize_rd(buffer_read_finalize),

    .buffer_id_valid(buffer_data_valid),
    .buffer_id(buffer_id_data)
);

task initialize_buffer_states;
    write_base_addr <= `WRAP_SIM(#1) 'd0;
    upload_buffer_idx <= `WRAP_SIM(#1) 'd0;

    read_base_addr <= `WRAP_SIM(#1) 'd0;
    download_buffer_idx <= `WRAP_SIM(#1) 'd0;
endtask

initial
    initialize_buffer_states();

task get_base_addr(input logic [1:0] buffer_idx, output logic[20:0] buffer_addr);
    case (buffer_idx)
        0: buffer_addr = 'd0;
        1: buffer_addr = INPUT_IMAGE_WIDTH * INPUT_IMAGE_HEIGHT + 'd32;
        2: buffer_addr = 2 * (INPUT_IMAGE_WIDTH * INPUT_IMAGE_HEIGHT + 'd32);
        default: begin
            buffer_addr = 'd0;
`ifdef __ICARUS__
            logger.critical(module_name, "Invalid buffer index");
`endif
        end
    endcase
endtask

always@(posedge clk or negedge rst_n)
    if(!rst_n) begin
        initialize_buffer_states();

        buffer_write_rdy <= `WRAP_SIM(#1) 1'b0;
        buffer_read_rdy <= `WRAP_SIM(#1) 1'b0;
    end else begin
        if (downloading_state == DOWNLOADING_FIND_BUFFER) begin
            buffer_read_rdy <= `WRAP_SIM(#1) 1'b1;
        end else if (downloading_state == DOWNLOADING_SELECT_BUFFER) begin
            logic[20:0] buffer_addr;

            if (DEBUG_BUFFER_INDEX >= 0)
                get_base_addr(DEBUG_BUFFER_INDEX, buffer_addr);
            else
                get_base_addr(buffer_id_data, buffer_addr);

            read_base_addr <= `WRAP_SIM(#1) buffer_addr;
        end

        if (uploading_state == UPLOADING_FIND_BUFFER)
            buffer_write_rdy <= `WRAP_SIM(#1) 1'b1;
        else if (uploading_state == UPLOADING_SELECT_BUFFER) begin
            logic[20:0] buffer_addr;

            if (DEBUG_BUFFER_INDEX >= 0)
                get_base_addr(DEBUG_BUFFER_INDEX, buffer_addr);
            else
                get_base_addr(buffer_id_data, buffer_addr);

            write_base_addr <= `WRAP_SIM(#1) buffer_addr;
        end
    end

// ============ Frame uploading logic ============
initial begin
    uploading_state <= `WRAP_SIM(#1) UPLOADING_IDLE;
end

always@(posedge clk or negedge rst_n)
    if(!rst_n)
        buffer_write_finalize <= `WRAP_SIM(#1) 1'b0;
    else begin
        if (uploading_state == UPLOADING_RELEASE_BUFFER)
            buffer_write_finalize <= `WRAP_SIM(#1) 1'b1;
        else
            buffer_write_finalize <= `WRAP_SIM(#1) 1'b0;
    end

always@(posedge clk or negedge rst_n)
    if(!rst_n) begin
        producer_req <= `WRAP_SIM(#1) 1'b0;
    end else begin
        if (uploading_state == UPLOADING_LOCK_BUFFER)
            producer_req <= `WRAP_SIM(#1) 1'b1;
        else if (uploading_state == UPLOADING_SELECT_BUFFER) begin
            producer_req <= `WRAP_SIM(#1) 1'b0;
        end else if (uploading_state == UPLOADING_RELEASE_BUFFER_WAIT) begin
            producer_req <= `WRAP_SIM(#1) 1'b1;
        end else if (uploading_state == UPLOADING_RELEASE_BUFFER) begin
            producer_req <= `WRAP_SIM(#1) 1'b0;
        end
    end

initial
    start_uploading <= `WRAP_SIM(#1) 1'b0;

always@(posedge clk or negedge rst_n)
    if(!rst_n)
        start_uploading <= `WRAP_SIM(#1) 1'b0;
    else if (uploading_state == UPLOADING_SELECT_BUFFER)
        start_uploading <= `WRAP_SIM(#1) 1'b1;
    else
        start_uploading <= `WRAP_SIM(#1) 1'b0;

always@(posedge clk or negedge rst_n)
    if(!rst_n)
        uploading_state <= `WRAP_SIM(#1) UPLOADING_IDLE;
    else 
        uploading_state <= `WRAP_SIM(#1) uploading_next_state;

always @(*) begin
    uploading_next_state = uploading_state;
    case (uploading_state)
        UPLOADING_IDLE:
            uploading_next_state = UPLOADING_START_WAITE;
        UPLOADING_START_WAITE:
            if (uploading_start_cnt == MEMORY_INITIAL_DELAY) begin
                uploading_next_state = UPLOADING_LOCK_BUFFER;
            end
        UPLOADING_LOCK_BUFFER:
            if (shared_grant[FRAME_UPLOADER_IDX] == 1'b1)
                uploading_next_state = UPLOADING_FIND_BUFFER;
        UPLOADING_FIND_BUFFER: 
            if (buffer_data_valid)
                uploading_next_state = UPLOADING_SELECT_BUFFER;
        UPLOADING_SELECT_BUFFER: begin
            uploading_next_state = UPLOADING_START_PROCESS_FRAME;
        end
        UPLOADING_START_PROCESS_FRAME:
            uploading_next_state = UPLOADING_FRAME_DONE_WAIT;
        UPLOADING_FRAME_DONE_WAIT:
            if (uploading_finished)
                uploading_next_state = UPLOADING_RELEASE_BUFFER_WAIT;
        UPLOADING_RELEASE_BUFFER_WAIT:
            if (shared_grant[FRAME_UPLOADER_IDX] == 1'b1)
                uploading_next_state = UPLOADING_RELEASE_BUFFER;
        UPLOADING_RELEASE_BUFFER:
            uploading_next_state = UPLOADING_IDLE;
    endcase
end

// ============ Frame downloading logic ============

initial begin
    downloading_state <= `WRAP_SIM(#1) DOWNLOADING_IDLE;
end

always@(posedge clk or negedge rst_n)
    if(!rst_n)
        buffer_read_finalize <= `WRAP_SIM(#1) 1'b0;
    else begin
        if (downloading_state == DOWNLOADING_RELEASE_BUFFER)
            buffer_read_finalize <= `WRAP_SIM(#1) 1'b1;
        else
            buffer_read_finalize <= `WRAP_SIM(#1) 1'b0;
    end

always@(posedge clk or negedge rst_n)
    if(!rst_n) begin
        consumer_req <= `WRAP_SIM(#1) 1'b0;
    end else begin
        if (downloading_state == DOWNLOADING_LOCK_BUFFER)
            consumer_req <= `WRAP_SIM(#1) 1'b1;
        else if (downloading_state == DOWNLOADING_SELECT_BUFFER) begin
            consumer_req <= `WRAP_SIM(#1) 1'b0;
        end else if (downloading_state == DOWNLOADING_RELEASE_BUFFER_WAIT) begin
            consumer_req <= `WRAP_SIM(#1) 1'b1;
        end else if (downloading_state == DOWNLOADING_RELEASE_BUFFER) begin
            consumer_req <= `WRAP_SIM(#1) 1'b0;
        end
    end

initial
    start_downloading <= `WRAP_SIM(#1) 1'b0;

always@(posedge clk or negedge rst_n)
    if(!rst_n)
        start_downloading <= `WRAP_SIM(#1) 1'b0;
    else if (downloading_state == DOWNLOADING_SELECT_BUFFER)
        start_downloading <= `WRAP_SIM(#1) 1'b1;
    else
        start_downloading <= `WRAP_SIM(#1) 1'b0;

always@(posedge clk or negedge rst_n)
    if(!rst_n)
        downloading_state <= `WRAP_SIM(#1) DOWNLOADING_IDLE;
    else 
        downloading_state <= `WRAP_SIM(#1) downloading_next_state;

always @(*) begin
    downloading_next_state = downloading_state;
    case (downloading_state)
        DOWNLOADING_IDLE:
            downloading_next_state = DOWNLOADING_START_WAITE;
        DOWNLOADING_START_WAITE:
            if (uploading_start_cnt == MEMORY_INITIAL_DELAY) begin
                downloading_next_state = DOWNLOADING_LOCK_BUFFER;
            end
        DOWNLOADING_LOCK_BUFFER:
            if (shared_grant[FRAME_DOWNLOADER_IDX] == 1'b1)
                downloading_next_state = DOWNLOADING_FIND_BUFFER;
        DOWNLOADING_FIND_BUFFER: 
            if (buffer_data_valid)
                downloading_next_state = DOWNLOADING_SELECT_BUFFER;
        DOWNLOADING_SELECT_BUFFER:
            downloading_next_state = DOWNLOADING_START_PROCESS_FRAME;
        DOWNLOADING_START_PROCESS_FRAME:
            downloading_next_state = DOWNLOADING_FRAME_DONE_WAIT;
        DOWNLOADING_FRAME_DONE_WAIT:
            if (downloading_finished)
                downloading_next_state = DOWNLOADING_RELEASE_BUFFER_WAIT;
        DOWNLOADING_RELEASE_BUFFER_WAIT:
            if (shared_grant[FRAME_DOWNLOADER_IDX] == 1'b1)
                downloading_next_state = DOWNLOADING_RELEASE_BUFFER;
        DOWNLOADING_RELEASE_BUFFER:
            downloading_next_state = DOWNLOADING_IDLE;
    endcase
end

initial
    uploading_start_cnt <= `WRAP_SIM(#1) 'd0;

always @(posedge clk or negedge rst_n)
    if (!rst_n)
        uploading_start_cnt <= `WRAP_SIM(#1) 'd0;
    //else if (curr_state == CYC_DONE_WAITE)
    // start_cnt <= 'b0;
    else if(uploading_start_cnt === MEMORY_INITIAL_DELAY)
        uploading_start_cnt <= `WRAP_SIM(#1) uploading_start_cnt;
    else if((uploading_state ==  UPLOADING_START_WAITE) && init_done)
        uploading_start_cnt <= `WRAP_SIM(#1) uploading_start_cnt + 1'b1;

//===== Frame processing CTRL =====

FrameProcessingStates frame_processing_state;

always@(posedge clk or negedge rst_n)
    if(!rst_n) begin
        frame_processing_state <= `WRAP_SIM(#1) FRAME_PROCESSING_START;
    end else begin
        if (uploading_state === UPLOADING_START_PROCESS_FRAME &&
            frame_processing_state === FRAME_PROCESSING_START) begin
            upload_row_counter <= `WRAP_SIM(#1) 'd0;
            upload_col_counter <= `WRAP_SIM(#1) 'd0;

            frame_processing_state <= `WRAP_SIM(#1) FRAME_PROCESSING_WRITE_ROW;
`ifdef __ICARUS__
            logger.info(module_name, "Start frame loading");
`endif
        end else
            case (frame_processing_state)
                FRAME_PROCESSING_WRITE_ROW: ;
            endcase
    end

//===== pSRAM CTRL =====
always@(posedge clk or negedge rst_n)
    if(!rst_n) begin
        data_mask   <= `WRAP_SIM(#1)  'b0;
    end

endmodule
