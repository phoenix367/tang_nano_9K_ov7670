`include "timescale.v"
`include "camera_control_defs.vh"

`ifdef __ICARUS__
`include "svlogger.sv"
`endif

`define max2(v1, v2) ((v1) > (v2) ? (v1) : (v2))

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
    parameter MEMORY_INITIAL_DELAY = 'd152
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
      output load_rd_en,
      input load_queue_empty,
      input [16:0] load_queue_data,

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
    BUFFER_AVAILABLE,
    BUFFER_WRITE_BUSY,
    BUFFER_READ_BUSY,
    BUFFER_DISPLAYED,
    BUFFER_UPDATED
} BufferStates;

typedef enum {
    FRAME_PROCESSING_START,
    FRAME_PROCESSING_WRITE_ROW,
    FRAME_PROCESSING_DONE
} FrameProcessingStates;

localparam int TOTAL_MEMORY_SIZE = 22'd1 << 21;

function reg [5:0] burst_delay(input int burst);
    case (burst)
         16: burst_delay = 6'd15;
         32: burst_delay = 6'd19;
         64: burst_delay = 6'd27;
        128: burst_delay = 6'd43;
        default: $error("%m Invalid memory burst value");
    endcase
endfunction

localparam TCMD128 = burst_delay(MEMORY_BURST);

//localparam   TCMD128             = 6'd19;// burst 128 = 6'd43;
                                        // burst 64  = 6'd27;
                                        // burst 32  = 6'd19;
                                        // burst 16  = 6'd15;


function reg [5:0] get_num128(input int burst);
    reg [5:0] val;
    case (burst)
         16: val = 6'd4;
         32: val = 6'd8;
         64: val = 6'd16;
        128: val = 6'd32;
        default: $error("%m Invalid memory burst value");
    endcase

    return val;
endfunction

localparam NUM128 = get_num128(MEMORY_BURST);

//localparam   NUM128              = 6'd8;// burst 128 = 6'd32;
                                       // burst 64  = 6'd16;
                                       // burst 32  = 6'd8;
                                       // burst 16  = 6'd4;
UploadingStates uploading_state;
UploadingStates uploading_next_state;

DownloadingStates downloading_state;
DownloadingStates downloading_next_state;

reg [7:0] uploading_start_cnt;
reg [20:0] frame_addresses[NUM_FRAMES - 1:0];
BufferStates buffer_states[NUM_FRAMES - 1:0];

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

assign shared_req = {data_read_req, data_write_req, consumer_req, producer_req};
//assign start_uploading = (uploading_state == UPLOADING_START_PROCESS_FRAME);

//assign start_downloading = (downloading_state == DOWNLOADING_START_PROCESS_FRAME);

assign load_clk_o = clk;
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
                 .start(start_uploading), .queue_empty(load_queue_empty),
                 .queue_data(load_queue_data), .write_ack(shared_grant[DATA_WRITER_IDX]),
                 .rd_en(load_rd_en), .write_rq(data_write_req),
                 .write_addr(write_addr_o), .mem_wr_en(mem_wr_en),
                 .write_data(wr_data), .upload_done(uploading_finished), .base_addr(write_base_addr));

FrameDownloader #(
    .FRAME_WIDTH(OUTPUT_IMAGE_WIDTH), 
    .FRAME_HEIGHT(OUTPUT_IMAGE_HEIGHT),
    .ORIG_FRAME_WIDTH(INPUT_IMAGE_WIDTH), 
    .ORIG_FRAME_HEIGHT(INPUT_IMAGE_HEIGHT),
    .MEMORY_BURST(MEMORY_BURST)
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

generate
    genvar o;

    for (o = 0; o < NUM_FRAMES; o = o + 1) begin: blk_addresses
        initial begin
`ifdef __ICARUS__
            string format_str;
`endif

            frame_addresses[o] = o * (INPUT_IMAGE_WIDTH * INPUT_IMAGE_HEIGHT + MEMORY_BURST);

`ifdef __ICARUS__
            $sformat(format_str, "Set address %0h for frame %0d", frame_addresses[o], o);
            #1 logger.info(module_name, format_str);
`endif
        end

        initial
            buffer_states[o] <= `WRAP_SIM(#1) BUFFER_AVAILABLE;
    end
endgenerate

task find_upload_buffer_idx(output reg [1:0] o_idx);
    integer i;
    reg [2:0] idx;
`ifdef __ICARUS__
            string format_str;
`endif

    idx = 3'b111;

    for (i = 'd0; i < NUM_FRAMES; i = i + 1) begin
        if (buffer_states[i] == BUFFER_DISPLAYED) begin
            idx = i[1:0];
            //break;
        end
    end

    if (idx === 3'b111)
        for (i = 'd0; i < NUM_FRAMES; i = i + 1) begin
            if (buffer_states[i] == BUFFER_AVAILABLE) begin
                idx = i[1:0];
                //break;
            end
        end

    if (idx === 3'b111)
        for (i = 'd0; i < NUM_FRAMES; i = i + 1) begin
            if (buffer_states[i] == BUFFER_UPDATED) begin
                idx = i[1:0];
                //break;
            end
        end

`ifdef __ICARUS__
    if (idx === 3'b111) begin
        logger.error(module_name, "Can't find available buffer for data upload");
        $fatal;
    end else begin
        $sformat(format_str, "Select buffer %0d for frame data uploading", idx);
        logger.info(module_name, format_str);
    end
`endif
    o_idx = idx[1:0];
endtask

task find_download_buffer_idx(output reg [1:0] o_idx);
    integer i;
    reg [2:0] idx;
`ifdef __ICARUS__
            string format_str;
`endif

    idx = 3'b111;

    for (i = 'd0; i < NUM_FRAMES; i = i + 1) begin
        if (buffer_states[i] == BUFFER_UPDATED) begin
            idx = i[1:0];
            //break;
        end
    end

    if (idx === 3'b111)
        for (i = 'd0; i < NUM_FRAMES; i = i + 1) begin
            if (buffer_states[i] == BUFFER_AVAILABLE) begin
                idx = i[1:0];
                //break;
            end
        end

    if (idx === 3'b111)
        for (i = 'd0; i < NUM_FRAMES; i = i + 1) begin
            if (buffer_states[i] == BUFFER_DISPLAYED) begin
                idx = i[1:0];
                //break;
            end
        end

`ifdef __ICARUS__
    if (idx === 3'b111) begin
        logger.error(module_name, "Can't find available buffer for data download");
        $fatal;
    end else begin
        $sformat(format_str, "Select buffer %0d for frame data downloading", idx);
        logger.info(module_name, format_str);
    end
`endif
    o_idx = idx[1:0];
endtask

task initialize_buffer_states;
    integer o;

    for (o = 0; o < NUM_FRAMES; o = o + 1)
        buffer_states[o] <= `WRAP_SIM(#1) BUFFER_AVAILABLE;

    write_base_addr <= `WRAP_SIM(#1) 'd0;
    upload_buffer_idx <= `WRAP_SIM(#1) 'd0;

    read_base_addr <= `WRAP_SIM(#1) 'd0;
    download_buffer_idx <= `WRAP_SIM(#1) 'd0;
endtask

initial
    initialize_buffer_states();

always@(posedge clk or negedge rst_n)
    if(!rst_n) begin
        initialize_buffer_states();
    end else begin
        if (downloading_state == DOWNLOADING_FIND_BUFFER) begin
            `WRAP_SIM(#1) find_download_buffer_idx(download_buffer_idx);
        end else if (downloading_state == DOWNLOADING_SELECT_BUFFER) begin
            buffer_states[download_buffer_idx] <= `WRAP_SIM(#1) BUFFER_WRITE_BUSY;
            read_base_addr <= `WRAP_SIM(#1) frame_addresses[download_buffer_idx];
        end else if (downloading_state == DOWNLOADING_RELEASE_BUFFER) begin
            buffer_states[download_buffer_idx] <= `WRAP_SIM(#1) BUFFER_DISPLAYED;
        end

        if (uploading_state == UPLOADING_FIND_BUFFER)
            `WRAP_SIM(#1) find_upload_buffer_idx(upload_buffer_idx);
        else if (uploading_state == UPLOADING_SELECT_BUFFER) begin
            buffer_states[upload_buffer_idx] <= `WRAP_SIM(#1) BUFFER_WRITE_BUSY;
            write_base_addr <= `WRAP_SIM(#1) frame_addresses[upload_buffer_idx];
        end else if (uploading_state == UPLOADING_RELEASE_BUFFER) begin
            buffer_states[upload_buffer_idx] <= `WRAP_SIM(#1) BUFFER_UPDATED;
        end
    end

// ============ Frame uploading logic ============
initial begin
    uploading_state <= `WRAP_SIM(#1) UPLOADING_IDLE;
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
        //cmd         <= `WRAP_SIM(#1) 1'b0;
        //cmd_en      <= `WRAP_SIM(#1) 1'b0;
        //addr        <= `WRAP_SIM(#1)  'b0;
        //wr_data     <= `WRAP_SIM(#1)  'b0;
        data_mask   <= `WRAP_SIM(#1)  'b0;
        //addr_add_w  <= `WRAP_SIM(#1)  'b0;
        //addr_add_r  <= `WRAP_SIM(#1)  'b0;
        //wr_data_add <= `WRAP_SIM(#1)  'b0;
    end

endmodule
