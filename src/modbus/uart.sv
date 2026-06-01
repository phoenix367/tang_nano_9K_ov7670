`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`default_nettype wire

// Full-duplex UART, 8 data bits, 1 even parity bit, 1 stop bit (8-E-1).
//
// Frame on the wire (LSB first): start(0), d0..d7, parity, stop(1). The even
// parity bit is the XOR of the 8 data bits (so the data+parity ones-count is
// even). Baud rate is CLK_FREQ / BAUD clocks per bit; the receiver samples each
// bit at its mid-point after a 2-FF synchroniser on `rx`.
//
//   transmit : present tx_data + pulse tx_start while !tx_busy; tx_busy stays
//              high until the stop bit completes.
//   receive  : rx_valid pulses for one clock when a byte arrives; rx_data holds
//              it, rx_parity_error / rx_frame_error flag a bad parity / stop bit
//              for that same byte.

module uart
#(
    parameter integer CLK_FREQ = 27_000_000,
    parameter integer BAUD     = 9600
)
(
    input  wire       clk,
    input  wire       reset_n,

    // transmit
    input  wire [7:0] tx_data,
    input  wire       tx_start,
    output reg        tx_busy,
    output reg        tx,

    // receive
    input  wire       rx,
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    output reg        rx_parity_error,
    output reg        rx_frame_error
);

    localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD;
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;

    localparam [2:0] T_IDLE = 3'd0, T_START = 3'd1, T_DATA = 3'd2,
                     T_PAR  = 3'd3, T_STOP  = 3'd4;
    localparam [2:0] R_IDLE = 3'd0, R_START = 3'd1, R_DATA = 3'd2,
                     R_PAR  = 3'd3, R_STOP  = 3'd4;

    // -------------------- transmitter --------------------
    reg [2:0]  t_state;
    reg [15:0] t_cnt;
    reg [2:0]  t_bit;
    reg [7:0]  t_shift;
    reg        t_par;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            t_state <= `WRAP_SIM(#1) T_IDLE;
            t_cnt   <= `WRAP_SIM(#1) 'd0;
            t_bit   <= `WRAP_SIM(#1) 'd0;
            t_shift <= `WRAP_SIM(#1) 'd0;
            t_par   <= `WRAP_SIM(#1) 1'b0;
            tx      <= `WRAP_SIM(#1) 1'b1;   // idle high
            tx_busy <= `WRAP_SIM(#1) 1'b0;
        end else begin
            case (t_state)
                T_IDLE: begin
                    tx      <= `WRAP_SIM(#1) 1'b1;
                    tx_busy <= `WRAP_SIM(#1) 1'b0;
                    if (tx_start) begin
                        t_shift <= `WRAP_SIM(#1) tx_data;
                        t_par   <= `WRAP_SIM(#1) ^tx_data;   // even parity
                        tx_busy <= `WRAP_SIM(#1) 1'b1;
                        tx      <= `WRAP_SIM(#1) 1'b0;        // start bit
                        t_cnt   <= `WRAP_SIM(#1) 'd0;
                        t_state <= `WRAP_SIM(#1) T_START;
                    end
                end
                T_START: begin
                    if (t_cnt == CLKS_PER_BIT - 1) begin
                        t_cnt   <= `WRAP_SIM(#1) 'd0;
                        t_bit   <= `WRAP_SIM(#1) 'd0;
                        tx      <= `WRAP_SIM(#1) t_shift[0];
                        t_state <= `WRAP_SIM(#1) T_DATA;
                    end else
                        t_cnt <= `WRAP_SIM(#1) t_cnt + 1'b1;
                end
                T_DATA: begin
                    tx <= `WRAP_SIM(#1) t_shift[0];
                    if (t_cnt == CLKS_PER_BIT - 1) begin
                        t_cnt   <= `WRAP_SIM(#1) 'd0;
                        t_shift <= `WRAP_SIM(#1) {1'b0, t_shift[7:1]};
                        if (t_bit == 3'd7) begin
                            tx      <= `WRAP_SIM(#1) t_par;
                            t_state <= `WRAP_SIM(#1) T_PAR;
                        end else
                            t_bit <= `WRAP_SIM(#1) t_bit + 1'b1;
                    end else
                        t_cnt <= `WRAP_SIM(#1) t_cnt + 1'b1;
                end
                T_PAR: begin
                    tx <= `WRAP_SIM(#1) t_par;
                    if (t_cnt == CLKS_PER_BIT - 1) begin
                        t_cnt   <= `WRAP_SIM(#1) 'd0;
                        tx      <= `WRAP_SIM(#1) 1'b1;        // stop bit
                        t_state <= `WRAP_SIM(#1) T_STOP;
                    end else
                        t_cnt <= `WRAP_SIM(#1) t_cnt + 1'b1;
                end
                T_STOP: begin
                    tx <= `WRAP_SIM(#1) 1'b1;
                    if (t_cnt == CLKS_PER_BIT - 1) begin
                        t_cnt   <= `WRAP_SIM(#1) 'd0;
                        tx_busy <= `WRAP_SIM(#1) 1'b0;
                        t_state <= `WRAP_SIM(#1) T_IDLE;
                    end else
                        t_cnt <= `WRAP_SIM(#1) t_cnt + 1'b1;
                end
                default: t_state <= `WRAP_SIM(#1) T_IDLE;
            endcase
        end
    end

    // -------------------- receiver --------------------
    reg        rx_d1, rx_d2;   // 2-FF synchroniser
    reg [2:0]  r_state;
    reg [15:0] r_cnt;
    reg [2:0]  r_bit;
    reg [7:0]  r_shift;
    reg        r_par;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_d1 <= `WRAP_SIM(#1) 1'b1;
            rx_d2 <= `WRAP_SIM(#1) 1'b1;
        end else begin
            rx_d1 <= `WRAP_SIM(#1) rx;
            rx_d2 <= `WRAP_SIM(#1) rx_d1;
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            r_state         <= `WRAP_SIM(#1) R_IDLE;
            r_cnt           <= `WRAP_SIM(#1) 'd0;
            r_bit           <= `WRAP_SIM(#1) 'd0;
            r_shift         <= `WRAP_SIM(#1) 'd0;
            r_par           <= `WRAP_SIM(#1) 1'b0;
            rx_data         <= `WRAP_SIM(#1) 'd0;
            rx_valid        <= `WRAP_SIM(#1) 1'b0;
            rx_parity_error <= `WRAP_SIM(#1) 1'b0;
            rx_frame_error  <= `WRAP_SIM(#1) 1'b0;
        end else begin
            rx_valid <= `WRAP_SIM(#1) 1'b0;   // one-cycle strobe

            case (r_state)
                R_IDLE: begin
                    if (rx_d2 == 1'b0) begin              // start bit edge
                        r_cnt   <= `WRAP_SIM(#1) 'd0;
                        r_state <= `WRAP_SIM(#1) R_START;
                    end
                end
                R_START: begin                            // re-check at mid start bit
                    if (r_cnt == HALF_BIT - 1) begin
                        if (rx_d2 == 1'b0) begin
                            r_cnt   <= `WRAP_SIM(#1) 'd0;
                            r_bit   <= `WRAP_SIM(#1) 'd0;
                            r_state <= `WRAP_SIM(#1) R_DATA;
                        end else
                            r_state <= `WRAP_SIM(#1) R_IDLE;  // false start
                    end else
                        r_cnt <= `WRAP_SIM(#1) r_cnt + 1'b1;
                end
                R_DATA: begin                             // sample at each bit mid-point
                    if (r_cnt == CLKS_PER_BIT - 1) begin
                        r_cnt   <= `WRAP_SIM(#1) 'd0;
                        r_shift <= `WRAP_SIM(#1) {rx_d2, r_shift[7:1]};  // LSB first
                        if (r_bit == 3'd7)
                            r_state <= `WRAP_SIM(#1) R_PAR;
                        else
                            r_bit <= `WRAP_SIM(#1) r_bit + 1'b1;
                    end else
                        r_cnt <= `WRAP_SIM(#1) r_cnt + 1'b1;
                end
                R_PAR: begin
                    if (r_cnt == CLKS_PER_BIT - 1) begin
                        r_cnt   <= `WRAP_SIM(#1) 'd0;
                        r_par   <= `WRAP_SIM(#1) rx_d2;
                        r_state <= `WRAP_SIM(#1) R_STOP;
                    end else
                        r_cnt <= `WRAP_SIM(#1) r_cnt + 1'b1;
                end
                R_STOP: begin
                    if (r_cnt == CLKS_PER_BIT - 1) begin
                        r_cnt           <= `WRAP_SIM(#1) 'd0;
                        rx_data         <= `WRAP_SIM(#1) r_shift;
                        rx_valid        <= `WRAP_SIM(#1) 1'b1;
                        rx_parity_error <= `WRAP_SIM(#1) (r_par != (^r_shift));
                        rx_frame_error  <= `WRAP_SIM(#1) (rx_d2 != 1'b1);  // stop must be high
                        r_state         <= `WRAP_SIM(#1) R_IDLE;
                    end else
                        r_cnt <= `WRAP_SIM(#1) r_cnt + 1'b1;
                end
                default: r_state <= `WRAP_SIM(#1) R_IDLE;
            endcase
        end
    end

endmodule
