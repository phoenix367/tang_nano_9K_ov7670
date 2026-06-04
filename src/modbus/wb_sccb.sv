`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`default_nettype wire

// Wishbone B4 classic-standard slave: live OV7670 register access over SCCB.
//
// Split out of the old monolithic modbus_cam_backend. Owns the OV7670 register
// range (0x0000..0x00C9). Each bus access becomes one SCCB transaction on the
// shared i2c_control_fsm:
//   * write (we=1): store the register index (wb_adr_i[7:0]) and the value
//     (wb_dat_i[7:0]) into the i2c controller, then pulse send_data.
//   * read  (we=0): store the register index, pulse recv_data, and return the byte
//     the controller reads back as wb_dat_o = {8'h00, value}.
//
// The pulse sequencing mirrors the power-on init FSM in camera_control.v, so it
// drives i2c_control_fsm exactly the way the proven init path does.
//
// Init gate: the slave stays in G_IDLE with wb_ack_o low until cam_init_complete &&
// device_rdy, so the power-on register load owns the SCCB bus undisturbed and the
// master simply stalls (classic-standard wait states) on a camera access during
// init. Status/grab/osd live on other slaves, so their accesses still complete
// while a camera access is gated -- the interconnect masks this slave's ack when
// it is not selected.
//
// wb_ack_o is a Moore output asserted only in S_RESP (one cycle). The old ACK/DRAIN
// states are gone: the master deasserts cyc/stb on the ack cycle, so a one-cycle
// ack then return-to-idle cannot double-trigger.

module wb_sccb (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        cam_init_complete,  // gate: 1 once camera init has finished

    // Wishbone B4 classic-standard slave
    input  wire [15:0] wb_adr_i,
    input  wire [15:0] wb_dat_i,
    output reg  [15:0] wb_dat_o,
    input  wire        wb_we_i,
    input  wire        wb_stb_i,
    input  wire        wb_cyc_i,
    output wire        wb_ack_o,

    // i2c_control_fsm handshake (drive store/send/recv + data_in; observe
    // device_rdy / data_valid / data_out)
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
        G_IDLE       = 5'd0,
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
        S_RESP       = 5'd13;   // assert ack for one cycle

    reg [4:0] state;

    wire sel = wb_stb_i & wb_cyc_i;

    assign busy     = (state != G_IDLE);
    assign wb_ack_o = (state == S_RESP);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state      <= `WRAP_SIM(#1) G_IDLE;
            store_data <= `WRAP_SIM(#1) 1'b0;
            send_data  <= `WRAP_SIM(#1) 1'b0;
            recv_data  <= `WRAP_SIM(#1) 1'b0;
            i2c_din    <= `WRAP_SIM(#1) 8'h00;
            wb_dat_o   <= `WRAP_SIM(#1) 16'h0000;
        end else begin
            case (state)
                // wait for a selected access. Camera registers wait for init to
                // release the SCCB bus (cam_init_complete && device_rdy); until
                // then ack stays low and the master stalls.
                G_IDLE: begin
                    store_data <= `WRAP_SIM(#1) 1'b0;
                    send_data  <= `WRAP_SIM(#1) 1'b0;
                    recv_data  <= `WRAP_SIM(#1) 1'b0;
                    if (sel && cam_init_complete && device_rdy)
                        state <= `WRAP_SIM(#1) wb_we_i ? W_STORE_ADDR : R_STORE_ADDR;
                end

                // ---- write: two stores (index, value) then send ----
                W_STORE_ADDR: begin
                    store_data <= `WRAP_SIM(#1) 1'b1;
                    i2c_din    <= `WRAP_SIM(#1) wb_adr_i[7:0];
                    state      <= `WRAP_SIM(#1) W_STORE_VAL;
                end
                W_STORE_VAL: begin
                    store_data <= `WRAP_SIM(#1) 1'b1;       // held high across both stores
                    i2c_din    <= `WRAP_SIM(#1) wb_dat_i[7:0];
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
                        wb_dat_o <= `WRAP_SIM(#1) 16'h0000;
                        state    <= `WRAP_SIM(#1) S_RESP;
                    end
                end

                // ---- read: single store (index) then recv ----
                R_STORE_ADDR: begin
                    store_data <= `WRAP_SIM(#1) 1'b1;
                    i2c_din    <= `WRAP_SIM(#1) wb_adr_i[7:0];
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
                        wb_dat_o <= `WRAP_SIM(#1) {8'h00, i2c_dout};
                        state    <= `WRAP_SIM(#1) S_RESP;
                    end
                end

                S_RESP:  // ack asserted (combinational) this cycle; return to idle
                    state <= `WRAP_SIM(#1) G_IDLE;

                default: state <= `WRAP_SIM(#1) G_IDLE;
            endcase
        end
    end

endmodule
