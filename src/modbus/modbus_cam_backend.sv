`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`default_nettype wire

// Bridges the modbus_rtu_slave register-backend handshake (be_*) to a live
// OV7670 SCCB access through the existing i2c_control_fsm. Each Modbus register
// access becomes one SCCB transaction:
//   * write (be_we=1): store the register index (be_addr[7:0]) and the value
//     (be_wdata[7:0]) into the i2c controller, then pulse send_data.
//   * read  (be_we=0): store the register index, pulse recv_data, and return the
//     byte the controller reads back as be_rdata = {8'h00, value}.
//
// The pulse sequencing mirrors the power-on init FSM in camera_control.v
// (store_data held across the two stores for a write; a single store for a
// read), so it drives i2c_control_fsm exactly the way the proven init path does.
//
// Init contention: the bridge stays idle until cam_init_complete is high, so the
// power-on register load owns the SCCB bus undisturbed; only after init does the
// bridge service Modbus accesses ("block until init done").
//
// Reserved status registers (above the OV7670 range, served directly without an
// SCCB cycle and regardless of cam_init_complete, so the host can poll them even
// during camera init):
//   * 0xF0 -> firmware magic 0xA5 (identifies the bridge)
//   * 0xF1 -> uptime high byte (latches the 16-bit counter for a coherent pair)
//   * 0xF2 -> uptime low byte
// The uptime counter is 0 at reset and free-runs, so a host that sees it jump
// backward knows the device was hard-reset.

module modbus_cam_backend
#(
    // Free-running uptime counter increments every UPTIME_DIV clk cycles
    // (~1 Hz at 27 MHz). Exposed via a reserved status register so the host can
    // detect a hard reset: on reset_n the counter restarts at 0, so the host
    // sees it jump backward. Override small in simulation.
    parameter integer UPTIME_DIV = 27_000_000
)
(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        cam_init_complete,  // gate: 1 once camera init has finished

    // register-backend handshake (connect to modbus_rtu_slave be_*)
    input  wire        be_req,
    input  wire        be_we,
    input  wire [15:0] be_addr,
    input  wire [15:0] be_wdata,
    output reg         be_ready,
    output reg  [15:0] be_rdata,

    // i2c_control_fsm handshake (drive its store/send/recv + data_in;
    // observe its device_rdy / data_valid / data_out)
    output reg         store_data,
    output reg         send_data,
    output reg         recv_data,
    output reg  [7:0]  i2c_din,
    input  wire        device_rdy,
    input  wire        data_valid,
    input  wire [7:0]  i2c_dout,

    output wire        busy,

    // pulse: re-run the power-on camera initialization (reset to defaults)
    output reg         cam_reinit,

    // channel-1 PSRAM bring-up loopback (to/from psram_ch1 via VGA_timing)
    output reg         grab_arm,        // pulse: capture the next frame into ch1
    output reg         grab_rd_req,     // pulse: read the ch1 burst at grab_rd_addr
    output reg [20:0]  grab_rd_addr,    // ch1 read address (burst-aligned)
    input  wire        grab_busy,
    input  wire [255:0] grab_rd_data,   // full 8-word burst returned by a ch1 read
    input  wire        grab_calib,
    input  wire [4:0]  wd_health        // watchdog: [4]=monitoring [3]=any-hang [2]=cam [1]=mem [0]=lcd
);
    localparam [4:0]
        IDLE         = 5'd0,
        W_STORE_ADDR = 5'd1,
        W_STORE_VAL  = 5'd2,
        W_STORE_DONE = 5'd3,
        W_SEND       = 5'd4,
        W_SEND_CLR   = 5'd5,
        W_WAIT_RDY   = 5'd6,
        R_STORE_ADDR = 5'd7,
        R_STORE_DONE = 5'd8,
        R_STORE_WAIT = 5'd9,
        R_RECV       = 5'd10,
        R_RECV_CLR   = 5'd11,
        R_WAIT_VALID = 5'd12,
        ACK          = 5'd13,
        DRAIN        = 5'd14,
        // ---- streaming frame download (FC03 over the stream band) ----
        S_STRM       = 5'd15,   // decide: fetch a fresh burst or serve from buffer
        S_FETCH0     = 5'd16,   // pulse grab_rd_req for the burst at s_baddr
        S_FETCH1     = 5'd17,   // wait for grab_busy to assert
        S_FETCH2     = 5'd18,   // wait for grab_busy to deassert, capture the burst
        S_SERVE      = 5'd19;   // return the current 16-bit pixel, advance the pointer

    reg [4:0] state;

    assign busy = (state != IDLE);

    // ---- reserved status registers (served directly, no SCCB, even during
    // camera init). They sit above the OV7670 register range so they never
    // collide with a real camera register.
    localparam [7:0]  STATUS_MAGIC   = 8'hA5;       // identifies the bridge firmware
    localparam [15:0] CAM_ADDR_MAX   = 16'h00C9,    // OV7670 registers 0x00..0xC9
                      ADDR_MAGIC      = 16'h00F0,
                      ADDR_UPTIME_HI  = 16'h00F1,
                      ADDR_UPTIME_LO  = 16'h00F2,
                      ADDR_GRAB       = 16'h00F3,    // write 1=arm grab, 2=read-trigger; read: status
                      ADDR_RDADDR_LO  = 16'h00F4,    // write: ch1 read addr [15:0]
                      ADDR_RDADDR_HI  = 16'h00F5,    // write: ch1 read addr [20:16]
                      ADDR_RDDATA_HI  = 16'h00F6,    // read: ch1 word [31:16]
                      ADDR_RDDATA_LO  = 16'h00F7,    // read: ch1 word [15:0]
                      ADDR_STREAM     = 16'h00F8,    // write: reset the download stream to ch1 addr 0
                      ADDR_HEALTH     = 16'h00F9,    // read: watchdog health bits (see wd_health)
                      ADDR_REINIT     = 16'h00FA,    // write 1: re-run camera init (reset to defaults)
                      STREAM_BASE     = 16'h1000;    // any read >= here returns the next frame pixel

    localparam [20:0] BSTEP = 21'd16;                // ch1 burst-address increment (matches the grab)

    // ---- streaming download pointer (FC03 over the stream band) -------------
    // A read of any address >= STREAM_BASE returns the next 16-bit pixel of the
    // captured frame and advances the pointer, so a host walks the whole frame
    // with back-to-back FC03 bursts. A write to ADDR_STREAM rewinds to pixel 0.
    // Each ch1 read returns a full 8-word (16-pixel) burst, buffered here and
    // drained 16 pixels at a time before the next burst is fetched.
    reg [20:0]  s_baddr;        // ch1 burst address of the buffered burst
    reg [2:0]   s_widx;         // current 32-bit word within the burst (0..7)
    reg         s_half;         // 0 = low pixel [15:0], 1 = high pixel [31:16]
    reg         s_loaded;       // s_burst holds the burst at s_baddr
    reg [255:0] s_burst;        // buffered 8-word burst
    wire [31:0] s_word = s_burst[s_widx*32 +: 32];

    reg [15:0] uptime;          // free-running seconds-ish, 0 on reset
    reg [15:0] uptime_latch;    // captured on a high-byte read for a coherent pair
    reg [31:0] uptime_div;

    wire is_camera = (be_addr <= CAM_ADDR_MAX);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state      <= `WRAP_SIM(#1) IDLE;
            store_data <= `WRAP_SIM(#1) 1'b0;
            send_data  <= `WRAP_SIM(#1) 1'b0;
            recv_data  <= `WRAP_SIM(#1) 1'b0;
            i2c_din    <= `WRAP_SIM(#1) 8'h00;
            be_ready   <= `WRAP_SIM(#1) 1'b0;
            be_rdata   <= `WRAP_SIM(#1) 16'h0000;
            uptime       <= `WRAP_SIM(#1) 16'h0000;
            uptime_latch <= `WRAP_SIM(#1) 16'h0000;
            uptime_div   <= `WRAP_SIM(#1) 32'h0;
            cam_reinit   <= `WRAP_SIM(#1) 1'b0;
            grab_arm     <= `WRAP_SIM(#1) 1'b0;
            grab_rd_req  <= `WRAP_SIM(#1) 1'b0;
            grab_rd_addr <= `WRAP_SIM(#1) 21'd0;
            s_baddr      <= `WRAP_SIM(#1) 21'd0;
            s_widx       <= `WRAP_SIM(#1) 3'd0;
            s_half       <= `WRAP_SIM(#1) 1'b0;
            s_loaded     <= `WRAP_SIM(#1) 1'b0;
            s_burst      <= `WRAP_SIM(#1) 256'd0;
        end else begin
            cam_reinit  <= `WRAP_SIM(#1) 1'b0;      // 1-cycle pulse defaults
            grab_arm    <= `WRAP_SIM(#1) 1'b0;
            grab_rd_req <= `WRAP_SIM(#1) 1'b0;
            // free-running uptime tick (independent of the SCCB FSM)
            if (uptime_div >= UPTIME_DIV - 1) begin
                uptime_div <= `WRAP_SIM(#1) 32'h0;
                uptime     <= `WRAP_SIM(#1) uptime + 1'b1;
            end else
                uptime_div <= `WRAP_SIM(#1) uptime_div + 1'b1;

            case (state)
                // wait for a backend request. Camera registers wait for the init
                // to release the SCCB bus (device_rdy); reserved status registers
                // are served directly, no SCCB, even during init.
                IDLE: begin
                    store_data <= `WRAP_SIM(#1) 1'b0;
                    send_data  <= `WRAP_SIM(#1) 1'b0;
                    recv_data  <= `WRAP_SIM(#1) 1'b0;
                    be_ready   <= `WRAP_SIM(#1) 1'b0;
                    if (be_req) begin
                        if (!be_we && be_addr >= STREAM_BASE) begin
                            // frame download: serve the next pixel of the stream
                            state <= `WRAP_SIM(#1) S_STRM;
                        end else if (is_camera) begin
                            if (cam_init_complete && device_rdy)
                                state <= `WRAP_SIM(#1) be_we ? W_STORE_ADDR : R_STORE_ADDR;
                            // else: block until init done
                        end else begin
                            // reserved register: answer immediately (writes ignored)
                            case (be_addr)
                                ADDR_MAGIC:
                                    be_rdata <= `WRAP_SIM(#1) {8'h00, STATUS_MAGIC};
                                ADDR_UPTIME_HI: begin
                                    be_rdata     <= `WRAP_SIM(#1) {8'h00, uptime[15:8]};
                                    uptime_latch <= `WRAP_SIM(#1) uptime;
                                end
                                ADDR_UPTIME_LO:
                                    be_rdata <= `WRAP_SIM(#1) {8'h00, uptime_latch[7:0]};
                                ADDR_GRAB: begin
                                    // read: [0]=busy [1]=calib
                                    be_rdata <= `WRAP_SIM(#1) {14'd0, grab_calib, grab_busy};
                                    if (be_we) begin
                                        if (be_wdata[1:0] == 2'd1) grab_arm    <= `WRAP_SIM(#1) 1'b1;
                                        if (be_wdata[1:0] == 2'd2) grab_rd_req <= `WRAP_SIM(#1) 1'b1;
                                    end
                                end
                                ADDR_RDADDR_LO: begin
                                    be_rdata <= `WRAP_SIM(#1) 16'd0;
                                    if (be_we) grab_rd_addr[15:0] <= `WRAP_SIM(#1) be_wdata;
                                end
                                ADDR_RDADDR_HI: begin
                                    be_rdata <= `WRAP_SIM(#1) 16'd0;
                                    if (be_we) grab_rd_addr[20:16] <= `WRAP_SIM(#1) be_wdata[4:0];
                                end
                                ADDR_RDDATA_HI:
                                    be_rdata <= `WRAP_SIM(#1) grab_rd_data[31:16];
                                ADDR_RDDATA_LO:
                                    be_rdata <= `WRAP_SIM(#1) grab_rd_data[15:0];
                                ADDR_STREAM: begin
                                    // rewind the download stream to ch1 pixel 0
                                    be_rdata <= `WRAP_SIM(#1) 16'd0;
                                    if (be_we) begin
                                        s_baddr  <= `WRAP_SIM(#1) 21'd0;
                                        s_widx   <= `WRAP_SIM(#1) 3'd0;
                                        s_half   <= `WRAP_SIM(#1) 1'b0;
                                        s_loaded <= `WRAP_SIM(#1) 1'b0;
                                    end
                                end
                                ADDR_HEALTH:
                                    // watchdog board health (read-only)
                                    be_rdata <= `WRAP_SIM(#1) {11'd0, wd_health};
                                ADDR_REINIT: begin
                                    // write 1 = re-run camera init (reset to defaults)
                                    be_rdata <= `WRAP_SIM(#1) 16'd0;
                                    if (be_we && be_wdata[0]) cam_reinit <= `WRAP_SIM(#1) 1'b1;
                                end
                                default:
                                    be_rdata <= `WRAP_SIM(#1) 16'h0000;
                            endcase
                            state <= `WRAP_SIM(#1) ACK;
                        end
                    end
                end

                // ---- write: two stores (index, value) then send ----
                W_STORE_ADDR: begin
                    store_data <= `WRAP_SIM(#1) 1'b1;
                    i2c_din    <= `WRAP_SIM(#1) be_addr[7:0];
                    state      <= `WRAP_SIM(#1) W_STORE_VAL;
                end
                W_STORE_VAL: begin
                    store_data <= `WRAP_SIM(#1) 1'b1;       // held high across both stores
                    i2c_din    <= `WRAP_SIM(#1) be_wdata[7:0];
                    state      <= `WRAP_SIM(#1) W_STORE_DONE;
                end
                W_STORE_DONE: begin
                    store_data <= `WRAP_SIM(#1) 1'b0;
                    state      <= `WRAP_SIM(#1) W_SEND;
                end
                W_SEND: begin
                    send_data <= `WRAP_SIM(#1) 1'b1;
                    state     <= `WRAP_SIM(#1) W_SEND_CLR;
                end
                W_SEND_CLR: begin
                    send_data <= `WRAP_SIM(#1) 1'b0;
                    state     <= `WRAP_SIM(#1) W_WAIT_RDY;
                end
                W_WAIT_RDY: begin
                    if (device_rdy) begin            // transaction returned to WAIT_COMMAND
                        be_rdata <= `WRAP_SIM(#1) 16'h0000;
                        state    <= `WRAP_SIM(#1) ACK;
                    end
                end

                // ---- read: single store (index) then recv ----
                R_STORE_ADDR: begin
                    store_data <= `WRAP_SIM(#1) 1'b1;
                    i2c_din    <= `WRAP_SIM(#1) be_addr[7:0];
                    state      <= `WRAP_SIM(#1) R_STORE_DONE;
                end
                R_STORE_DONE: begin
                    store_data <= `WRAP_SIM(#1) 1'b0;
                    state      <= `WRAP_SIM(#1) R_STORE_WAIT;
                end
                R_STORE_WAIT: begin
                    if (device_rdy)                  // back in WAIT_COMMAND after the store
                        state <= `WRAP_SIM(#1) R_RECV;
                end
                R_RECV: begin
                    recv_data <= `WRAP_SIM(#1) 1'b1;
                    state     <= `WRAP_SIM(#1) R_RECV_CLR;
                end
                R_RECV_CLR: begin
                    recv_data <= `WRAP_SIM(#1) 1'b0;
                    state     <= `WRAP_SIM(#1) R_WAIT_VALID;
                end
                R_WAIT_VALID: begin
                    if (data_valid) begin
                        be_rdata <= `WRAP_SIM(#1) {8'h00, i2c_dout};
                        state    <= `WRAP_SIM(#1) ACK;
                    end
                end

                // ---- streaming frame download (one pixel per backend read) ----
                S_STRM: state <= `WRAP_SIM(#1) s_loaded ? S_SERVE : S_FETCH0;
                S_FETCH0: begin                       // request the burst at s_baddr
                    grab_rd_addr <= `WRAP_SIM(#1) s_baddr;
                    grab_rd_req  <= `WRAP_SIM(#1) 1'b1;   // 1-cycle pulse (default clears it)
                    state        <= `WRAP_SIM(#1) S_FETCH1;
                end
                S_FETCH1: if (grab_busy) state <= `WRAP_SIM(#1) S_FETCH2;  // read accepted
                S_FETCH2: if (!grab_busy) begin       // burst complete; capture it
                    s_burst  <= `WRAP_SIM(#1) grab_rd_data;
                    s_loaded <= `WRAP_SIM(#1) 1'b1;
                    state    <= `WRAP_SIM(#1) S_SERVE;
                end
                S_SERVE: begin                        // return the current pixel, advance
                    be_rdata <= `WRAP_SIM(#1) s_half ? s_word[31:16] : s_word[15:0];
                    if (!s_half) begin
                        s_half <= `WRAP_SIM(#1) 1'b1;
                    end else begin
                        s_half <= `WRAP_SIM(#1) 1'b0;
                        if (s_widx == 3'd7) begin     // burst drained -> next burst
                            s_widx   <= `WRAP_SIM(#1) 3'd0;
                            s_baddr  <= `WRAP_SIM(#1) s_baddr + BSTEP;
                            s_loaded <= `WRAP_SIM(#1) 1'b0;
                        end else
                            s_widx <= `WRAP_SIM(#1) s_widx + 3'd1;
                    end
                    state <= `WRAP_SIM(#1) ACK;
                end

                // ---- ack the backend, then wait for be_req to drop ----
                ACK: begin
                    be_ready <= `WRAP_SIM(#1) 1'b1;
                    state    <= `WRAP_SIM(#1) DRAIN;
                end
                DRAIN: begin
                    be_ready <= `WRAP_SIM(#1) 1'b0;
                    if (!be_req)
                        state <= `WRAP_SIM(#1) IDLE;
                end

                default: state <= `WRAP_SIM(#1) IDLE;
            endcase
        end
    end

endmodule
