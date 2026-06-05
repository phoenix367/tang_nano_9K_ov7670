// Clock-domain crossing for SERV's Wishbone ext-bus master (Phase 2b).
//
// SERV runs on mcu_clk (30 MHz, mcu_rpll); the camera's Wishbone bus + be_arbiter
// + wb_* slaves run on sys_clk (27 MHz). The two come from separate PLLs (30:27,
// non-integer) and are asynchronous, so SERV's master handshake must be
// synchronized as it crosses into the bus domain.
//
// SERV's ext bus is a single-outstanding, 4-phase handshake: it asserts s_stb and
// holds s_we/s_adr/s_dat stable until s_ack. So only the req/done QUALIFIERS need
// 2-FF synchronizers (CDC_Bit_Synchronizer); the multi-bit fields are sampled in
// the far domain while the synchronized qualifier guarantees they're stable
// (standard handshake CDC -- no per-bit word synchronizer required). A full
// return-to-zero on both sides ensures one transaction completes before the next.

`default_nettype none
module serv_wb_cdc
   (// mcu domain -- SERV ext bus
    input  wire        mcu_clk,
    input  wire        mcu_rst,        // active high
    input  wire        s_stb,
    input  wire        s_we,
    input  wire [15:0] s_adr,
    input  wire [15:0] s_dat,
    output reg         s_ack,
    output reg  [15:0] s_rdt,

    // sys domain -- be_arbiter m1 port
    input  wire        sys_clk,
    input  wire        sys_rst_n,      // active low
    output reg         m_req,
    output reg         m_we,
    output reg  [15:0] m_addr,
    output reg  [15:0] m_wdata,
    input  wire        m_ready,
    input  wire [15:0] m_rdata);

    // ---- qualifiers crossing the boundary ----
    reg        req_level;              // mcu: high for the duration of a request
    wire       req_sys;                // sync of req_level into sys domain
    reg        done_sys;              // sys: high once the bus access completed
    wire       done_mcu;              // sync of done_sys into mcu domain
    reg [15:0] rdt_hold;              // sys: captured read data (stable while done_sys)

    CDC_Bit_Synchronizer #(.EXTRA_DEPTH(0)) sync_req
        (.receiving_clock(sys_clk), .bit_in(req_level), .bit_out(req_sys));
    CDC_Bit_Synchronizer #(.EXTRA_DEPTH(0)) sync_done
        (.receiving_clock(mcu_clk), .bit_in(done_sys), .bit_out(done_mcu));

    // ---- mcu-side FSM (faces SERV) ----
    localparam U_IDLE = 2'd0, U_REQ = 2'd1, U_ACK = 2'd2;
    reg [1:0] ustate;
    always @(posedge mcu_clk or posedge mcu_rst)
        if (mcu_rst) begin
            ustate <= U_IDLE; req_level <= 1'b0; s_ack <= 1'b0; s_rdt <= 16'h0;
        end else begin
            s_ack <= 1'b0;                          // 1-cycle ack by default
            case (ustate)
                U_IDLE: if (s_stb) begin req_level <= 1'b1; ustate <= U_REQ; end
                U_REQ:  if (done_mcu) begin          // bus access finished
                            s_rdt     <= rdt_hold;   // stable (held while done)
                            s_ack     <= 1'b1;       // tell SERV (1 cycle)
                            req_level <= 1'b0;        // start return-to-zero
                            ustate    <= U_ACK;
                        end
                U_ACK:  if (!done_mcu) ustate <= U_IDLE;  // full RTZ before next req
                default: ustate <= U_IDLE;
            endcase
        end

    // ---- sys-side FSM (faces be_arbiter) ----
    localparam V_IDLE = 2'd0, V_RUN = 2'd1, V_DONE = 2'd2;
    reg [1:0] vstate;
    always @(posedge sys_clk or negedge sys_rst_n)
        if (!sys_rst_n) begin
            vstate <= V_IDLE; m_req <= 1'b0; m_we <= 1'b0;
            m_addr <= 16'h0; m_wdata <= 16'h0; done_sys <= 1'b0; rdt_hold <= 16'h0;
        end else begin
            case (vstate)
                V_IDLE: if (req_sys) begin            // s_* are stable now
                            m_we    <= s_we;
                            m_addr  <= s_adr;
                            m_wdata <= s_dat;
                            m_req   <= 1'b1;
                            vstate  <= V_RUN;
                        end
                V_RUN:  if (m_ready) begin
                            rdt_hold <= m_rdata;
                            m_req    <= 1'b0;
                            done_sys <= 1'b1;
                            vstate   <= V_DONE;
                        end
                V_DONE: if (!req_sys) begin done_sys <= 1'b0; vstate <= V_IDLE; end
                default: vstate <= V_IDLE;
            endcase
        end
endmodule
`default_nettype wire
