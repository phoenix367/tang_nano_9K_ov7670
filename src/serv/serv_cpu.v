// SERV CPU wrapper for use as a Wishbone master inside the camera design
// (Phase 2). Combines the SERV core (servile) with the proven 32-bit
// servant_ram (program/data, $readmemh-preloaded) and serv_rf_ram (register
// file), and exposes only the Wishbone "ext" peripheral master bus. This is
// servant.v minus its on-chip timer/gpio/mux -- we route o_wb_ext_* out to the
// camera's Wishbone interconnect instead.
//
// memfile is the firmware hex (32-bit words, one per line; see serv_soc/bin2hex.py);
// it is passed in from camera_control.v via the `SERV_MEMFILE macro (build_config.vh).

`default_nettype none
module serv_cpu
  #(parameter memfile        = "",
    parameter memsize        = 8192,
    parameter reset_strategy = "MINI",
    parameter [0:0] with_csr = 1'b1)
   (input  wire        i_clk,
    input  wire        i_rst,        // active high
    input  wire        i_timer_irq,

    output wire [31:0] o_wb_ext_adr,
    output wire [31:0] o_wb_ext_dat,
    output wire [3:0]  o_wb_ext_sel,
    output wire        o_wb_ext_we,
    output wire        o_wb_ext_stb,
    input  wire [31:0] i_wb_ext_rdt,
    input  wire        i_wb_ext_ack);

   localparam width    = 1;
   localparam csr_regs = with_csr*4;
   localparam rf_width = width*2;
   localparam rf_l2d   = $clog2((32+csr_regs)*32/rf_width);

   wire [31:0] wb_mem_adr;
   wire [31:0] wb_mem_dat;
   wire [3:0]  wb_mem_sel;
   wire        wb_mem_we;
   wire        wb_mem_stb;
   wire [31:0] wb_mem_rdt;
   wire        wb_mem_ack;

   wire [rf_l2d-1:0]   rf_waddr;
   wire [rf_width-1:0] rf_wdata;
   wire                rf_wen;
   wire [rf_l2d-1:0]   rf_raddr;
   wire                rf_ren;
   wire [rf_width-1:0] rf_rdata;

   servant_ram
     #(.memfile (memfile),
       .depth   (memsize),
       .RESET_STRATEGY (reset_strategy))
   ram
     (.i_wb_clk (i_clk),
      .i_wb_rst (i_rst),
      .i_wb_adr (wb_mem_adr[$clog2(memsize)-1:2]),
      .i_wb_dat (wb_mem_dat),
      .i_wb_sel (wb_mem_sel),
      .i_wb_we  (wb_mem_we),
      .i_wb_cyc (wb_mem_stb),
      .o_wb_rdt (wb_mem_rdt),
      .o_wb_ack (wb_mem_ack));

   serv_rf_ram
     #(.width    (rf_width),
       .csr_regs (csr_regs))
   rf_ram
     (.i_clk   (i_clk),
      .i_waddr (rf_waddr),
      .i_wdata (rf_wdata),
      .i_wen   (rf_wen),
      .i_raddr (rf_raddr),
      .i_ren   (rf_ren),
      .o_rdata (rf_rdata));

   servile
     #(.width    (width),
       .reset_strategy (reset_strategy),
       .sim      (1'b0),
       .debug    (1'b0),
       .with_c   (1'b0),
       .with_csr (with_csr),
       .with_mdu (1'b0))
   cpu
     (.i_clk       (i_clk),
      .i_rst       (i_rst),
      .i_timer_irq (i_timer_irq),

      .o_wb_mem_adr (wb_mem_adr),
      .o_wb_mem_dat (wb_mem_dat),
      .o_wb_mem_sel (wb_mem_sel),
      .o_wb_mem_we  (wb_mem_we),
      .o_wb_mem_stb (wb_mem_stb),
      .i_wb_mem_rdt (wb_mem_rdt),
      .i_wb_mem_ack (wb_mem_ack),

      .o_wb_ext_adr (o_wb_ext_adr),
      .o_wb_ext_dat (o_wb_ext_dat),
      .o_wb_ext_sel (o_wb_ext_sel),
      .o_wb_ext_we  (o_wb_ext_we),
      .o_wb_ext_stb (o_wb_ext_stb),
      .i_wb_ext_rdt (i_wb_ext_rdt),
      .i_wb_ext_ack (i_wb_ext_ack),

      .o_rf_waddr (rf_waddr),
      .o_rf_wdata (rf_wdata),
      .o_rf_wen   (rf_wen),
      .o_rf_raddr (rf_raddr),
      .o_rf_ren   (rf_ren),
      .i_rf_rdata (rf_rdata));
endmodule
`default_nettype wire
