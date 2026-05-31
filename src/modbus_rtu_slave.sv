`include "timescale.v"
`include "camera_control_defs.vh"

`default_nettype wire

// Modbus RTU slave (server) sitting on the UART byte layer (src/uart.sv, 8-E-1).
//
// Implements the Modbus-over-serial-line RTU mode for a block of 16-bit holding
// registers:
//   * 0x03 Read Holding Registers
//   * 0x06 Write Single Register
//   * 0x10 Write Multiple Registers
// with exception responses (0x01 illegal function, 0x02 illegal data address,
// 0x03 illegal data value). Framing is by the t3.5 silent interval: a frame ends
// when the RX line is idle for >= 3.5 character times. CRC-16/Modbus
// (poly 0xA001, init 0xFFFF, LSB-first) is checked on RX -- a correct frame's
// CRC over all bytes is 0 -- and appended (low byte first) on TX. Bad CRC,
// wrong address, parity error, or overflow -> the frame is silently dropped.
// Address 0 is broadcast: writes are applied but no response is sent.
//
// Register storage is pluggable through a backend handshake (be_*). With
// EXTERNAL_BACKEND=0 (default) a tiny internal single-cycle RAM backend holds
// the registers and exposes them on reg_o / accepts host_we writes -- this is
// the original behaviour, unchanged. With EXTERNAL_BACKEND=1 every register
// access (FC03 read, FC06/FC10 write) is issued on the be_* port and the FSM
// stalls until be_ready, so a slow external backend (e.g. an SCCB bridge to a
// camera) can service each register live. The protocol FSM is identical in both
// modes; only where the registers physically live differs.

module modbus_rtu_slave
#(
    parameter integer CLK_FREQ  = 27_000_000,
    parameter integer BAUD      = 9600,
    parameter [7:0]   SLAVE_ADDR = 8'd7,
    parameter integer REG_COUNT = 16,
    parameter integer MAX_FRAME = 64,
    parameter integer EXTERNAL_BACKEND = 0   // 0 = internal RAM, 1 = be_* port
)
(
    input  wire        clk,
    input  wire        reset_n,

    // UART receive (from uart.sv)
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire        rx_parity_error,

    // UART transmit (to uart.sv)
    output reg  [7:0]  tx_data,
    output reg         tx_start,
    input  wire        tx_busy,

    // holding registers exposed to the design (register i in bits [16*i +: 16]);
    // valid only with the internal backend (EXTERNAL_BACKEND=0), else 0.
    output wire [16*REG_COUNT-1:0] reg_o,

    // optional host write port (design updates a register; only the low
    // $clog2(REG_COUNT) bits of host_addr are used). Internal backend only.
    input  wire                       host_we,
    input  wire [7:0]                 host_addr,
    input  wire [15:0]                host_wdata,

    // external register backend (used when EXTERNAL_BACKEND=1). One access at a
    // time: assert be_req with be_we/be_addr(/be_wdata); the backend pulses
    // be_ready when done (be_rdata valid that cycle for a read).
    output reg         be_req,
    output reg         be_we,
    output reg  [15:0] be_addr,
    output reg  [15:0] be_wdata,
    input  wire        be_ready,
    input  wire [15:0] be_rdata
);
    localparam integer REG_AW    = (REG_COUNT <= 1) ? 1 : $clog2(REG_COUNT);
    localparam integer FW        = (MAX_FRAME <= 1) ? 1 : $clog2(MAX_FRAME) + 1;
    localparam integer BIT_CYC   = CLK_FREQ / BAUD;
    localparam integer CHAR_CYC  = 11 * BIT_CYC;          // 1 char = 11 bits (8-E-1)
    localparam integer T35       = (7 * CHAR_CYC) / 2;    // 3.5 character times

    // exception codes
    localparam [7:0] EXC_ILLEGAL_FUNC = 8'h01,
                     EXC_ILLEGAL_ADDR = 8'h02,
                     EXC_ILLEGAL_VAL  = 8'h03;

    localparam [3:0] S_RX      = 4'd0,
                     S_CHECK   = 4'd1,
                     S_RD_REQ  = 4'd2,   // FC03: issue one register read
                     S_RD_CAP  = 4'd3,   // FC03: wait + capture be_rdata
                     S_WR_REQ  = 4'd4,   // FC06/FC10: issue one register write
                     S_WR_WAIT = 4'd5,   // FC06/FC10: wait for be_ready
                     S_TX_LOAD = 4'd6,
                     S_TX_PEND = 4'd7,
                     S_TX_WAIT = 4'd8,
                     S_DONE    = 4'd9,
                     S_DECIDE  = 4'd10;  // 2nd decode stage: shallow select from flags

    reg [3:0]  state;
    reg [7:0]  frame [0:MAX_FRAME-1];
    reg [7:0]  resp  [0:MAX_FRAME-1];
    reg [FW-1:0] flen, rlen, tidx;
    reg [15:0] crc_acc;     // RX CRC accumulator
    reg [15:0] tx_crc;      // TX CRC accumulator
    reg [31:0] t35_cnt;
    reg        frame_ovf, frame_perr;

    reg [15:0] saddr, qty, cur, wval;
    reg [7:0]  bidx;        // data-loop index (registers)
    reg        is_bcast;
    reg        wr_multi;    // S_WR_* loop: 0 = single (FC06), 1 = multiple (FC10)

    // S_CHECK latches the request fields and the (registered) bounds/validity
    // flags; S_DECIDE then only does a shallow select. This keeps the 27 MHz
    // decode path short -- it previously did all the arithmetic + the function
    // decode combinationally into `state` in a single cycle.
    reg [7:0]  f_dev, f_func, qlast;
    reg        v_bad, v_qty0, v_addr_oor, v_saddr_oor, v_oversize, v_bc_bad;

    // ---------------- backend: internal RAM (default) or external port -------
    wire        eff_be_ready;
    wire [15:0] eff_be_rdata;

    genvar gi;
    generate
        if (EXTERNAL_BACKEND == 0) begin : g_int_be
            reg [15:0] holding [0:REG_COUNT-1];
            integer    j;

            // single-cycle combinational ack; read is combinational, write is
            // registered on the be_req&be_we cycle.
            assign eff_be_ready = be_req;
            assign eff_be_rdata = holding[be_addr[REG_AW-1:0]];

            for (gi = 0; gi < REG_COUNT; gi = gi + 1) begin : g_rego
                assign reg_o[16*gi +: 16] = holding[gi];
            end

            always @(posedge clk or negedge reset_n) begin
                if (!reset_n) begin
                    for (j = 0; j < REG_COUNT; j = j + 1)
                        holding[j] <= `WRAP_SIM(#1) 16'h0000;
                end else begin
                    if (host_we)
                        holding[host_addr[REG_AW-1:0]] <= `WRAP_SIM(#1) host_wdata;
                    if (be_req && be_we)
                        holding[be_addr[REG_AW-1:0]] <= `WRAP_SIM(#1) be_wdata;
                end
            end
        end else begin : g_ext_be
            assign eff_be_ready = be_ready;
            assign eff_be_rdata = be_rdata;
            assign reg_o = {(16*REG_COUNT){1'b0}};
        end
    endgenerate

    // CRC-16/Modbus byte update
    function [15:0] crc16_update(input [15:0] crc_in, input [7:0] b);
        logic [15:0] c;
        integer i;
        begin
            c = crc_in ^ {8'h00, b};
            for (i = 0; i < 8; i = i + 1)
                c = c[0] ? ((c >> 1) ^ 16'hA001) : (c >> 1);
            crc16_update = c;
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state      <= `WRAP_SIM(#1) S_RX;
            flen       <= `WRAP_SIM(#1) 'd0;
            rlen       <= `WRAP_SIM(#1) 'd0;
            tidx       <= `WRAP_SIM(#1) 'd0;
            crc_acc    <= `WRAP_SIM(#1) 16'hFFFF;
            tx_crc     <= `WRAP_SIM(#1) 16'hFFFF;
            t35_cnt    <= `WRAP_SIM(#1) 'd0;
            frame_ovf  <= `WRAP_SIM(#1) 1'b0;
            frame_perr <= `WRAP_SIM(#1) 1'b0;
            tx_start   <= `WRAP_SIM(#1) 1'b0;
            tx_data    <= `WRAP_SIM(#1) 8'h00;
            is_bcast   <= `WRAP_SIM(#1) 1'b0;
            wr_multi   <= `WRAP_SIM(#1) 1'b0;
            be_req     <= `WRAP_SIM(#1) 1'b0;
            be_we      <= `WRAP_SIM(#1) 1'b0;
            be_addr    <= `WRAP_SIM(#1) 16'h0000;
            be_wdata   <= `WRAP_SIM(#1) 16'h0000;
        end else begin
            tx_start <= `WRAP_SIM(#1) 1'b0;

            case (state)
                // ---------------- receive a frame, end on t3.5 silence ----------------
                S_RX: begin
                    if (rx_valid) begin
                        t35_cnt <= `WRAP_SIM(#1) 'd0;
                        crc_acc <= `WRAP_SIM(#1) (flen == 0) ? crc16_update(16'hFFFF, rx_data)
                                                             : crc16_update(crc_acc, rx_data);
                        if (rx_parity_error) frame_perr <= `WRAP_SIM(#1) 1'b1;
                        if (flen < MAX_FRAME[FW-1:0]) begin
                            frame[flen] <= `WRAP_SIM(#1) rx_data;
                            flen        <= `WRAP_SIM(#1) flen + 1'b1;
                        end else
                            frame_ovf <= `WRAP_SIM(#1) 1'b1;
                    end else if (flen != 0) begin
                        if (t35_cnt >= T35[31:0]) state <= `WRAP_SIM(#1) S_CHECK;
                        else t35_cnt <= `WRAP_SIM(#1) t35_cnt + 1'b1;
                    end
                end

                // -------- stage 1: latch fields + compute bounds/validity --------
                // All the heavy arithmetic (16-bit adds, the >REG_COUNT /
                // MAX_FRAME compares, the validity OR) lands in registers here, so
                // the next-state logic in S_DECIDE is a shallow mux on flags.
                S_CHECK: begin
                    f_dev    <= `WRAP_SIM(#1) frame[0];
                    f_func   <= `WRAP_SIM(#1) frame[1];
                    saddr    <= `WRAP_SIM(#1) {frame[2], frame[3]};
                    qty      <= `WRAP_SIM(#1) {frame[4], frame[5]};
                    cur      <= `WRAP_SIM(#1) {frame[2], frame[3]};
                    wval     <= `WRAP_SIM(#1) {frame[4], frame[5]};
                    qlast    <= `WRAP_SIM(#1) {frame[4], frame[5]} - 16'd1;  // loop terminal (qty-1)
                    bidx     <= `WRAP_SIM(#1) 'd0;
                    tidx     <= `WRAP_SIM(#1) 'd0;
                    tx_crc   <= `WRAP_SIM(#1) 16'hFFFF;
                    is_bcast <= `WRAP_SIM(#1) (frame[0] == 8'h00);

                    v_bad       <= `WRAP_SIM(#1) frame_ovf || frame_perr || flen < 4 ||
                                       crc_acc != 16'h0000 ||
                                       (frame[0] != SLAVE_ADDR && frame[0] != 8'h00);
                    v_qty0      <= `WRAP_SIM(#1) ({frame[4],frame[5]} == 16'd0);
                    v_addr_oor  <= `WRAP_SIM(#1) (({frame[2],frame[3]} + {frame[4],frame[5]}) > REG_COUNT);
                    v_saddr_oor <= `WRAP_SIM(#1) ({frame[2],frame[3]} >= REG_COUNT);
                    v_oversize  <= `WRAP_SIM(#1) (({frame[4],frame[5]} << 1) + 16'd3 > MAX_FRAME);
                    v_bc_bad    <= `WRAP_SIM(#1) (frame[6] != ({frame[4],frame[5]} << 1));

                    state    <= `WRAP_SIM(#1) S_DECIDE;
                end

                // -------- stage 2: select response/next-state from the flags --------
                // No frame[] reads, no bound arithmetic here -- just a mux on the
                // registered flags/fields, so the path into `state` stays short.
                S_DECIDE: begin
                    if (v_bad) begin
                        state <= `WRAP_SIM(#1) S_DONE;           // drop, no reply
                    end else begin
                        case (f_func)
                            8'h03: begin // read holding registers
                                resp[0] <= `WRAP_SIM(#1) f_dev;
                                if (v_qty0 || v_oversize) begin
                                    resp[1] <= `WRAP_SIM(#1) 8'h83;
                                    resp[2] <= `WRAP_SIM(#1) EXC_ILLEGAL_VAL;
                                    rlen    <= `WRAP_SIM(#1) 'd3;
                                    state   <= `WRAP_SIM(#1) is_bcast ? S_DONE : S_TX_LOAD;
                                end else if (v_addr_oor) begin
                                    resp[1] <= `WRAP_SIM(#1) 8'h83;
                                    resp[2] <= `WRAP_SIM(#1) EXC_ILLEGAL_ADDR;
                                    rlen    <= `WRAP_SIM(#1) 'd3;
                                    state   <= `WRAP_SIM(#1) is_bcast ? S_DONE : S_TX_LOAD;
                                end else if (is_bcast) begin
                                    state <= `WRAP_SIM(#1) S_DONE;   // no read on broadcast
                                end else begin
                                    resp[1] <= `WRAP_SIM(#1) 8'h03;
                                    resp[2] <= `WRAP_SIM(#1) (qty << 1);
                                    rlen    <= `WRAP_SIM(#1) 'd3 + (qty << 1);
                                    state   <= `WRAP_SIM(#1) S_RD_REQ;
                                end
                            end
                            8'h06: begin // write single register
                                resp[0] <= `WRAP_SIM(#1) f_dev;
                                if (v_saddr_oor) begin
                                    resp[1] <= `WRAP_SIM(#1) 8'h86;
                                    resp[2] <= `WRAP_SIM(#1) EXC_ILLEGAL_ADDR;
                                    rlen    <= `WRAP_SIM(#1) 'd3;
                                    state   <= `WRAP_SIM(#1) is_bcast ? S_DONE : S_TX_LOAD;
                                end else begin
                                    resp[1] <= `WRAP_SIM(#1) f_func;
                                    resp[2] <= `WRAP_SIM(#1) saddr[15:8];
                                    resp[3] <= `WRAP_SIM(#1) saddr[7:0];
                                    resp[4] <= `WRAP_SIM(#1) wval[15:8];
                                    resp[5] <= `WRAP_SIM(#1) wval[7:0];
                                    rlen    <= `WRAP_SIM(#1) 'd6;
                                    wr_multi <= `WRAP_SIM(#1) 1'b0;
                                    state   <= `WRAP_SIM(#1) S_WR_REQ;
                                end
                            end
                            8'h10: begin // write multiple registers
                                resp[0] <= `WRAP_SIM(#1) f_dev;
                                if (v_qty0 || v_addr_oor || v_bc_bad) begin
                                    resp[1] <= `WRAP_SIM(#1) 8'h90;
                                    resp[2] <= `WRAP_SIM(#1) v_qty0 ? EXC_ILLEGAL_VAL : EXC_ILLEGAL_ADDR;
                                    rlen    <= `WRAP_SIM(#1) 'd3;
                                    state   <= `WRAP_SIM(#1) is_bcast ? S_DONE : S_TX_LOAD;
                                end else begin
                                    resp[1] <= `WRAP_SIM(#1) 8'h10;
                                    resp[2] <= `WRAP_SIM(#1) saddr[15:8];
                                    resp[3] <= `WRAP_SIM(#1) saddr[7:0];
                                    resp[4] <= `WRAP_SIM(#1) wval[15:8];
                                    resp[5] <= `WRAP_SIM(#1) wval[7:0];
                                    rlen    <= `WRAP_SIM(#1) 'd6;
                                    wr_multi <= `WRAP_SIM(#1) 1'b1;
                                    state   <= `WRAP_SIM(#1) S_WR_REQ;
                                end
                            end
                            default: begin // illegal function
                                resp[0] <= `WRAP_SIM(#1) f_dev;
                                resp[1] <= `WRAP_SIM(#1) f_func | 8'h80;
                                resp[2] <= `WRAP_SIM(#1) EXC_ILLEGAL_FUNC;
                                rlen    <= `WRAP_SIM(#1) 'd3;
                                state   <= `WRAP_SIM(#1) is_bcast ? S_DONE : S_TX_LOAD;
                            end
                        endcase
                    end
                end

                // ---------------- FC03: read register `cur` into resp ----------------
                S_RD_REQ: begin
                    be_req  <= `WRAP_SIM(#1) 1'b1;
                    be_we   <= `WRAP_SIM(#1) 1'b0;
                    be_addr <= `WRAP_SIM(#1) cur;
                    state   <= `WRAP_SIM(#1) S_RD_CAP;
                end
                S_RD_CAP: begin
                    if (eff_be_ready) begin
                        be_req <= `WRAP_SIM(#1) 1'b0;
                        resp[3 + (bidx << 1)]     <= `WRAP_SIM(#1) eff_be_rdata[15:8];
                        resp[3 + (bidx << 1) + 1] <= `WRAP_SIM(#1) eff_be_rdata[7:0];
                        if (bidx == qlast) begin
                            state <= `WRAP_SIM(#1) S_TX_LOAD;
                        end else begin
                            bidx  <= `WRAP_SIM(#1) bidx + 1'b1;
                            cur   <= `WRAP_SIM(#1) cur + 1'b1;
                            state <= `WRAP_SIM(#1) S_RD_REQ;
                        end
                    end
                end

                // ---------------- FC06/FC10: write register(s) via the backend --------
                S_WR_REQ: begin
                    be_req   <= `WRAP_SIM(#1) 1'b1;
                    be_we    <= `WRAP_SIM(#1) 1'b1;
                    be_addr  <= `WRAP_SIM(#1) cur;
                    be_wdata <= `WRAP_SIM(#1) wr_multi
                                  ? {frame[7 + (bidx << 1)], frame[8 + (bidx << 1)]}
                                  : wval;
                    state    <= `WRAP_SIM(#1) S_WR_WAIT;
                end
                S_WR_WAIT: begin
                    if (eff_be_ready) begin
                        be_req <= `WRAP_SIM(#1) 1'b0;
                        be_we  <= `WRAP_SIM(#1) 1'b0;
                        if (!wr_multi) begin
                            state <= `WRAP_SIM(#1) is_bcast ? S_DONE : S_TX_LOAD;
                        end else if (bidx == qlast) begin
                            state <= `WRAP_SIM(#1) is_bcast ? S_DONE : S_TX_LOAD;
                        end else begin
                            bidx  <= `WRAP_SIM(#1) bidx + 1'b1;
                            cur   <= `WRAP_SIM(#1) cur + 1'b1;
                            state <= `WRAP_SIM(#1) S_WR_REQ;
                        end
                    end
                end

                // ---------------- transmit response + CRC (low, high) ----------------
                S_TX_LOAD: begin
                    if (tidx == rlen + 2) begin
                        state <= `WRAP_SIM(#1) S_DONE;
                    end else if (!tx_busy) begin
                        if (tidx < rlen) begin
                            tx_data <= `WRAP_SIM(#1) resp[tidx];
                            tx_crc  <= `WRAP_SIM(#1) crc16_update(tx_crc, resp[tidx]);
                        end else if (tidx == rlen)
                            tx_data <= `WRAP_SIM(#1) tx_crc[7:0];
                        else
                            tx_data <= `WRAP_SIM(#1) tx_crc[15:8];
                        tx_start <= `WRAP_SIM(#1) 1'b1;
                        state    <= `WRAP_SIM(#1) S_TX_PEND;
                    end
                end
                S_TX_PEND: begin                 // wait for the UART to accept (busy asserts)
                    if (tx_busy) state <= `WRAP_SIM(#1) S_TX_WAIT;
                end
                S_TX_WAIT: begin                 // wait for the byte to finish
                    if (!tx_busy) begin
                        tidx  <= `WRAP_SIM(#1) tidx + 1'b1;
                        state <= `WRAP_SIM(#1) S_TX_LOAD;
                    end
                end

                // ---------------- frame done: rearm the receiver ----------------
                S_DONE: begin
                    flen       <= `WRAP_SIM(#1) 'd0;
                    t35_cnt    <= `WRAP_SIM(#1) 'd0;
                    crc_acc    <= `WRAP_SIM(#1) 16'hFFFF;
                    frame_ovf  <= `WRAP_SIM(#1) 1'b0;
                    frame_perr <= `WRAP_SIM(#1) 1'b0;
                    state      <= `WRAP_SIM(#1) S_RX;
                end

                default: state <= `WRAP_SIM(#1) S_RX;
            endcase
        end
    end

endmodule
