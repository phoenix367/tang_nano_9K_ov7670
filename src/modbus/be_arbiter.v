// Two-master arbiter for the modbus_cam_backend register-backend (be_*) handshake.
// Lets a second master (the SERV soft core, Phase 2) share the Wishbone control
// bus with the Modbus host path. Master 0 (the host) has priority; whichever
// master starts a multi-cycle access (be_req held while be_ready is still low)
// is owner-locked until be_ready so neither master is preempted mid-transaction.
// Single-cycle accesses (e.g. wb_sysregs, combinational ack) complete without
// ever locking. Each master speaks the same be_* protocol modbus_cam_backend
// already implements: assert *_req, hold until *_ready, capture *_rdata.

`default_nettype none
module be_arbiter
   (input  wire        clk,
    input  wire        reset_n,

    // master 0 (priority -- the Modbus host)
    input  wire        m0_req,
    input  wire        m0_we,
    input  wire [15:0] m0_addr,
    input  wire [15:0] m0_wdata,
    output wire        m0_ready,
    output wire [15:0] m0_rdata,

    // master 1 (the SERV co-master)
    input  wire        m1_req,
    input  wire        m1_we,
    input  wire [15:0] m1_addr,
    input  wire [15:0] m1_wdata,
    output wire        m1_ready,
    output wire [15:0] m1_rdata,

    // downstream backend (modbus_cam_backend be_*)
    output wire        be_req,
    output wire        be_we,
    output wire [15:0] be_addr,
    output wire [15:0] be_wdata,
    input  wire        be_ready,
    input  wire [15:0] be_rdata);

   reg busy;    // a granted transaction has lasted >1 cycle (owner is locked)
   reg owner;   // valid while busy: 0 = m0, 1 = m1

   // combinational priority pick when the bus is free (m0 wins ties)
   wire sel1_free = ~m0_req & m1_req;
   wire cur1      = busy ? owner : sel1_free;
   wire cur_req   = busy ? (owner ? m1_req : m0_req) : (m0_req | m1_req);

   assign be_req   = cur_req;
   assign be_we    = cur1 ? m1_we    : m0_we;
   assign be_addr  = cur1 ? m1_addr  : m0_addr;
   assign be_wdata = cur1 ? m1_wdata : m0_wdata;

   assign m0_ready = (~cur1) & cur_req & be_ready;
   assign m1_ready = ( cur1) & cur_req & be_ready;
   assign m0_rdata = be_rdata;
   assign m1_rdata = be_rdata;

   always @(posedge clk or negedge reset_n)
     if (!reset_n)
       busy <= 1'b0;
     else if (busy) begin
        if (be_ready) busy <= 1'b0;             // transaction finished
     end else if ((m0_req | m1_req) & ~be_ready) begin
        busy  <= 1'b1;                           // multi-cycle: lock the owner
        owner <= sel1_free;
     end
endmodule
`default_nettype wire
