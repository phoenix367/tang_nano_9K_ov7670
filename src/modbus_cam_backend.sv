`include "timescale.v"
`include "camera_control_defs.vh"

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

module modbus_cam_backend
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

    output wire        busy
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
        DRAIN        = 5'd14;

    reg [4:0] state;

    assign busy = (state != IDLE);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state      <= `WRAP_SIM(#1) IDLE;
            store_data <= `WRAP_SIM(#1) 1'b0;
            send_data  <= `WRAP_SIM(#1) 1'b0;
            recv_data  <= `WRAP_SIM(#1) 1'b0;
            i2c_din    <= `WRAP_SIM(#1) 8'h00;
            be_ready   <= `WRAP_SIM(#1) 1'b0;
            be_rdata   <= `WRAP_SIM(#1) 16'h0000;
        end else begin
            case (state)
                // wait for a backend request, but only once the camera init has
                // released the SCCB bus and the controller is idle (device_rdy).
                IDLE: begin
                    store_data <= `WRAP_SIM(#1) 1'b0;
                    send_data  <= `WRAP_SIM(#1) 1'b0;
                    recv_data  <= `WRAP_SIM(#1) 1'b0;
                    be_ready   <= `WRAP_SIM(#1) 1'b0;
                    if (be_req && cam_init_complete && device_rdy)
                        state <= `WRAP_SIM(#1) be_we ? W_STORE_ADDR : R_STORE_ADDR;
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
