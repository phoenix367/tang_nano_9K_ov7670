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
// Holding registers are exposed (flattened) on reg_o for the rest of the design,
// and the design can update one via the host_we/host_addr/host_wdata port.

module modbus_rtu_slave
#(
    parameter integer CLK_FREQ  = 27_000_000,
    parameter integer BAUD      = 9600,
    parameter [7:0]   SLAVE_ADDR = 8'd7,
    parameter integer REG_COUNT = 16,
    parameter integer MAX_FRAME = 64
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

    // holding registers exposed to the design (register i in bits [16*i +: 16])
    output wire [16*REG_COUNT-1:0] reg_o,

    // optional host write port (design updates a register; only the low
    // $clog2(REG_COUNT) bits of host_addr are used)
    input  wire                       host_we,
    input  wire [7:0]                 host_addr,
    input  wire [15:0]                host_wdata
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
                     S_BUILD03 = 4'd2,
                     S_WRITE10 = 4'd3,
                     S_TX_LOAD = 4'd4,
                     S_TX_PEND = 4'd5,
                     S_TX_WAIT = 4'd6,
                     S_DONE    = 4'd7;

    reg [3:0]  state;
    reg [7:0]  frame [0:MAX_FRAME-1];
    reg [7:0]  resp  [0:MAX_FRAME-1];
    reg [FW-1:0] flen, rlen, tidx;
    reg [15:0] crc_acc;     // RX CRC accumulator
    reg [15:0] tx_crc;      // TX CRC accumulator
    reg [31:0] t35_cnt;
    reg        frame_ovf, frame_perr;

    reg [15:0] saddr, qty, cur;
    reg [7:0]  bidx;        // data-loop index (registers)
    reg        is_bcast;

    reg [15:0] holding [0:REG_COUNT-1];

    genvar gi;
    generate
        for (gi = 0; gi < REG_COUNT; gi = gi + 1) begin : g_rego
            assign reg_o[16*gi +: 16] = holding[gi];
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

    integer k;

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
            for (k = 0; k < REG_COUNT; k = k + 1)
                holding[k] <= `WRAP_SIM(#1) 16'h0000;
        end else begin
            tx_start <= `WRAP_SIM(#1) 1'b0;

            // host-side register write (design driving a register the master reads)
            if (host_we)
                holding[host_addr[REG_AW-1:0]] <= `WRAP_SIM(#1) host_wdata;

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

                // ---------------- validate + decode ----------------
                S_CHECK: begin
                    saddr    <= `WRAP_SIM(#1) {frame[2], frame[3]};
                    qty      <= `WRAP_SIM(#1) {frame[4], frame[5]};
                    cur      <= `WRAP_SIM(#1) {frame[2], frame[3]};
                    bidx     <= `WRAP_SIM(#1) 'd0;
                    tidx     <= `WRAP_SIM(#1) 'd0;
                    tx_crc   <= `WRAP_SIM(#1) 16'hFFFF;
                    is_bcast <= `WRAP_SIM(#1) (frame[0] == 8'h00);

                    if (frame_ovf || frame_perr || flen < 4 || crc_acc != 16'h0000 ||
                        (frame[0] != SLAVE_ADDR && frame[0] != 8'h00)) begin
                        state <= `WRAP_SIM(#1) S_DONE;            // drop, no reply
                    end else begin
                        case (frame[1])
                            8'h03: begin // read holding registers
                                if ({frame[4],frame[5]} == 16'd0 ||
                                    ({frame[2],frame[3]} + {frame[4],frame[5]}) > REG_COUNT) begin
                                    resp[0] <= `WRAP_SIM(#1) frame[0];
                                    resp[1] <= `WRAP_SIM(#1) 8'h83;
                                    resp[2] <= `WRAP_SIM(#1) ({frame[4],frame[5]} == 16'd0)
                                                              ? EXC_ILLEGAL_VAL : EXC_ILLEGAL_ADDR;
                                    rlen    <= `WRAP_SIM(#1) 'd3;
                                    state   <= `WRAP_SIM(#1) (frame[0]==8'h00) ? S_DONE : S_TX_LOAD;
                                end else if (frame[0] == 8'h00) begin
                                    state <= `WRAP_SIM(#1) S_DONE;     // no read on broadcast
                                end else begin
                                    resp[0] <= `WRAP_SIM(#1) frame[0];
                                    resp[1] <= `WRAP_SIM(#1) 8'h03;
                                    resp[2] <= `WRAP_SIM(#1) ({frame[4],frame[5]} << 1);
                                    rlen    <= `WRAP_SIM(#1) 'd3;
                                    state   <= `WRAP_SIM(#1) S_BUILD03;
                                end
                            end
                            8'h06: begin // write single register
                                if ({frame[2],frame[3]} >= REG_COUNT) begin
                                    resp[0] <= `WRAP_SIM(#1) frame[0];
                                    resp[1] <= `WRAP_SIM(#1) 8'h86;
                                    resp[2] <= `WRAP_SIM(#1) EXC_ILLEGAL_ADDR;
                                    rlen    <= `WRAP_SIM(#1) 'd3;
                                    state   <= `WRAP_SIM(#1) (frame[0]==8'h00) ? S_DONE : S_TX_LOAD;
                                end else begin
                                    holding[frame[3][REG_AW-1:0]] <= `WRAP_SIM(#1) {frame[4], frame[5]};
                                    resp[0] <= `WRAP_SIM(#1) frame[0];
                                    resp[1] <= `WRAP_SIM(#1) frame[1];
                                    resp[2] <= `WRAP_SIM(#1) frame[2];
                                    resp[3] <= `WRAP_SIM(#1) frame[3];
                                    resp[4] <= `WRAP_SIM(#1) frame[4];
                                    resp[5] <= `WRAP_SIM(#1) frame[5];
                                    rlen    <= `WRAP_SIM(#1) 'd6;
                                    state   <= `WRAP_SIM(#1) (frame[0]==8'h00) ? S_DONE : S_TX_LOAD;
                                end
                            end
                            8'h10: begin // write multiple registers
                                if ({frame[4],frame[5]} == 16'd0 ||
                                    ({frame[2],frame[3]} + {frame[4],frame[5]}) > REG_COUNT ||
                                    frame[6] != ({frame[4],frame[5]} << 1)) begin
                                    resp[0] <= `WRAP_SIM(#1) frame[0];
                                    resp[1] <= `WRAP_SIM(#1) 8'h90;
                                    resp[2] <= `WRAP_SIM(#1) ({frame[4],frame[5]} == 16'd0)
                                                              ? EXC_ILLEGAL_VAL : EXC_ILLEGAL_ADDR;
                                    rlen    <= `WRAP_SIM(#1) 'd3;
                                    state   <= `WRAP_SIM(#1) (frame[0]==8'h00) ? S_DONE : S_TX_LOAD;
                                end else begin
                                    resp[0] <= `WRAP_SIM(#1) frame[0];
                                    resp[1] <= `WRAP_SIM(#1) 8'h10;
                                    resp[2] <= `WRAP_SIM(#1) frame[2];
                                    resp[3] <= `WRAP_SIM(#1) frame[3];
                                    resp[4] <= `WRAP_SIM(#1) frame[4];
                                    resp[5] <= `WRAP_SIM(#1) frame[5];
                                    rlen    <= `WRAP_SIM(#1) 'd6;
                                    state   <= `WRAP_SIM(#1) S_WRITE10;
                                end
                            end
                            default: begin // illegal function
                                resp[0] <= `WRAP_SIM(#1) frame[0];
                                resp[1] <= `WRAP_SIM(#1) frame[1] | 8'h80;
                                resp[2] <= `WRAP_SIM(#1) EXC_ILLEGAL_FUNC;
                                rlen    <= `WRAP_SIM(#1) 'd3;
                                state   <= `WRAP_SIM(#1) (frame[0]==8'h00) ? S_DONE : S_TX_LOAD;
                            end
                        endcase
                    end
                end

                // ---------------- FC03: emit register data into resp ----------------
                S_BUILD03: begin
                    resp[3 + (bidx << 1)]     <= `WRAP_SIM(#1) holding[cur[REG_AW-1:0]][15:8];
                    resp[3 + (bidx << 1) + 1] <= `WRAP_SIM(#1) holding[cur[REG_AW-1:0]][7:0];
                    if (bidx == qty[7:0] - 1) begin
                        rlen  <= `WRAP_SIM(#1) 'd3 + (qty[FW-1:0] << 1);
                        state <= `WRAP_SIM(#1) S_TX_LOAD;
                    end else begin
                        bidx <= `WRAP_SIM(#1) bidx + 1'b1;
                        cur  <= `WRAP_SIM(#1) cur + 1'b1;
                    end
                end

                // ---------------- FC10: write the registers from the frame ----------------
                S_WRITE10: begin
                    holding[cur[REG_AW-1:0]] <= `WRAP_SIM(#1) {frame[7 + (bidx << 1)], frame[8 + (bidx << 1)]};
                    if (bidx == qty[7:0] - 1) begin
                        state <= `WRAP_SIM(#1) is_bcast ? S_DONE : S_TX_LOAD;
                    end else begin
                        bidx <= `WRAP_SIM(#1) bidx + 1'b1;
                        cur  <= `WRAP_SIM(#1) cur + 1'b1;
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
