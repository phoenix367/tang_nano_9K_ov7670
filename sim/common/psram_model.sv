`include "timescale.v"
`include "svlogger.sv"

module W955D8MKY
#(
    parameter MODULE_NAME = "",
    parameter LOG_LEVEL = `SVL_VERBOSE_INFO
)
(
          input resetb,
          input clk,
          input clk_n,
          input ceb,
          inout [7:0] adq,
          inout rwds,
          input VCC,
          input VSS
);

localparam MEMORY_SIZE = 2097152; // Memory size in 16-bit words
DataLogger #(.name(MODULE_NAME), .verbosity(LOG_LEVEL)) logger();

string module_name;

reg rwds_o_oe;
reg adq_o_oe;
reg rwds_o;
reg [7:0] adq_o;
reg [4:0] command_addr_counter;
reg [7:0] command_addr[5:0];
reg [7:0] reg_data[2];
reg [15:0] conf_reg0;
reg [15:0] conf_reg1;
reg [20:0] mem_addr;
reg [7:0] rw_counter;
reg [7:0] rw_counter_next;
reg [4:0] delay_counter;
reg [7:0] burst_size;
reg [4:0] latency;
integer read_address;

reg [15:0] memory_area[MEMORY_SIZE];

integer i, d;

initial begin
    $sformat(module_name, "%m");

    rwds_o_oe <= #1 1'b0;
    rwds_o <= #1 1'b0;
    adq_o <= #1 8'b0;
    adq_o_oe <= #1 1'b0;
    mem_addr <= #1 21'h0;
    burst_size <= #1 8'd32;
    latency <= #1 5'd6;
end

always @(rw_counter) begin
    rw_counter_next = rw_counter + 1'b1;
end

always @(posedge ceb or posedge ~ceb) begin
    string str_ceb_state;
    $sformat(str_ceb_state, "CS state changed to %0d", ceb);

    logger.debug(module_name, str_ceb_state);
end

assign rwds = (rwds_o_oe) ? rwds_o : 1'bZ;
assign adq = (adq_o_oe) ? adq_o : 8'bZ;

always @(ceb, resetb) begin
    if (!resetb || ceb)
        rwds_o_oe = #1 1'b0;
    else if (!ceb)
        rwds_o_oe = #1 1'b1;
end

typedef enum {IDLE, WAIT_TRANSACTION, RECEIVE_COMMAND_ADDR, PROCESS_COMMAND,
              WRITE_MEMORY_DATA, READ_DELAY, READ_MEMORY_DATA} MemoryStates;
typedef enum {WRITE_TRANSACTION, READ_TRANSACTION} TransactionType;
typedef enum {MEMORY_SPACE, REG_SPACE} TransactionSpace;

MemoryStates memory_state;
TransactionType transaction_type;
TransactionSpace transaction_space;

task print_reg0_config(input reg [15:0] r);
    string str_format;

    logger.info(module_name, "Configuration Register 0 content:");

    $sformat(str_format, "    Deep Power Down Enable: %s", (r[15]) ? "OFF" : "ON");
    logger.info(module_name, str_format);

    case (r[14:12])
        3'b000: logger.info(module_name, "    Drive Strength: 50 ohms");
        3'b001: logger.info(module_name, "    Drive Strength: 35 ohms");
        3'b010: logger.info(module_name, "    Drive Strength: 100 ohms");
        3'b011: logger.info(module_name, "    Drive Strength: 200 ohms");
        default: begin
            logger.info(module_name, "    ERROR: Invalid Drive Strength value");
            $finish;
        end
    endcase
    
    case (r[7:4])
        4'b0000: begin
            latency = 5'd5;
            logger.info(module_name, "    Clock Latency: @ 5 - 133MHz Max Frequency");
        end
        4'b0001: begin
            latency = 5'd6;
            logger.info(module_name, "    Clock Latency: @ 6 - 166MHz Max Frequency");
        end
        4'b1110: begin
            latency = 5'd3;
            logger.info(module_name, "    Clock Latency: @ 3 - 83MHz Max Frequency");
        end
        4'b1111: begin
            latency = 5'd4;
            logger.info(module_name, "    Clock Latency: @ 4 - 104MHz Max Frequency");
        end
        default: begin
            logger.info(module_name, "    ERROR: Invalid Drive Strength value");
            $finish;
        end
    endcase

    if (!r[3])
        logger.info(module_name, "    Fixed Latency: No");
    else
        logger.info(module_name, "    Fixed Latency: Yes");

    if (r[2])
        logger.info(module_name, "    Wrapped burst sequences in legacy wrapped burst manner");

    case (r[1:0])
        2'b00: begin
            burst_size = 8'd128;
            logger.info(module_name, "    Burst Length - 128 bytes");
        end
        2'b01: begin
            burst_size = 8'd64;
            logger.info(module_name, "    Burst Length - 64 bytes");
        end
        2'b10: begin
            burst_size = 8'd16;
            logger.info(module_name, "    Burst Length - 16 bytes");
        end
        2'b11: begin
            burst_size = 8'd32;
            logger.info(module_name, "    Burst Length - 32 bytes");
        end
    endcase
endtask

task print_reg1_config(reg [15:0] r);
    string str_format;
    logger.info(module_name, "Configuration Register 1 content:");

    $sformat(str_format, "    HyperRAM refresh rate: %s", (r[6]) ? "normal" : "faster");
    logger.info(module_name, str_format);

    $sformat(str_format, "    Hybrid Sleep: %s", (r[6]) ? "ON" : "OFF");
    logger.info(module_name, str_format);
    
    case (r[2:0])
        3'b000: logger.info(module_name, "    Partial Array Refresh: Full array");
        3'b001: logger.info(module_name, "    Partial Array Refresh: Bottom 1/2 Array");
        3'b010: logger.info(module_name, "    Partial Array Refresh: Bottom 1/4 Array");
        3'b011: logger.info(module_name, "    Partial Array Refresh: Bottom 1/8 Array");
        3'b100: logger.info(module_name, "    Partial Array Refresh: None");
        3'b101: logger.info(module_name, "    Partial Array Refresh: Top 1/2 Array");
        3'b110: logger.info(module_name, "    Partial Array Refresh: Top 1/4 Array");
        3'b111: logger.info(module_name, "    Partial Array Refresh: Top 1/8 Array");
    endcase
endtask

function reg [20:0] cmd_addr_to_mem_addr(input reg [7:0] addr_i[5:0]);
    string str_format;
    reg [47:0] addr;

    addr[47:40] = addr_i[5];
    addr[39:32] = addr_i[4];
    addr[31:24] = addr_i[3];
    addr[23:16] = addr_i[2];
    addr[15:8] = addr_i[1];
    addr[7:0] = addr_i[0];

    cmd_addr_to_mem_addr[20:9] = addr[33:22];
    cmd_addr_to_mem_addr[8:3] = addr[21:16];
    cmd_addr_to_mem_addr[2:0] = addr[2:0];
endfunction

always @(memory_state, rw_counter) begin
    if (memory_state == WAIT_TRANSACTION)
        rwds_o = #1 1'b0;
    else if (memory_state == READ_MEMORY_DATA) begin
        rwds_o = (rw_counter[0] == 1'b1);
    end else
        rwds_o = #1 1'b0;
end

always @(posedge clk, posedge clk_n, negedge resetb) begin
    if (!resetb) begin
        memory_state = IDLE;
        command_addr_counter <= 5'h0;
        mem_addr <= #1 21'h0;
        adq_o_oe <= #1 1'b0;
    end else begin
        case (memory_state)
            IDLE: begin
                memory_state <= #1 WAIT_TRANSACTION;
                logger.info(module_name, "Switch to wait transaction");
            end
            WAIT_TRANSACTION: begin
                adq_o_oe <= #1 1'b0;

                if (!ceb) begin
                    command_addr[5] <= #1 adq;
                    memory_state <= #1 RECEIVE_COMMAND_ADDR;
                    command_addr_counter <= #1 5'd1;

                    if (adq[7]) begin
                        transaction_type <= #1 READ_TRANSACTION;
                        logger.info(module_name, "Start read transaction");
                    end else begin
                        transaction_type <= #1 WRITE_TRANSACTION;
                        logger.info(module_name, "Start write transaction");
                    end

                    if (adq[6]) begin
                        transaction_space <= #1 REG_SPACE;
                        logger.info(module_name, "process register space");
                    end else begin
                        transaction_space <= #1 MEMORY_SPACE;
                        logger.info(module_name, "process memory space");
                    end
                end
            end
            RECEIVE_COMMAND_ADDR: begin
                // Receive 6 bytes of address command
                if (command_addr_counter < 5'd6) begin
                    command_addr[5 - command_addr_counter] = #1 adq;
                    command_addr_counter = #1 command_addr_counter + 1'b1;

                // Receive next two bytes of register value if the previous command
                // is register writing
                end else if (command_addr_counter < 5'd8 && transaction_type == WRITE_TRANSACTION && transaction_space == REG_SPACE) begin
                    reg_data[7 - command_addr_counter] = #1 adq;
                    command_addr_counter = #1 command_addr_counter + 1'b1;
                end else begin
                    string str_format;
                    
                    memory_state <= #1 PROCESS_COMMAND;
                    for (i = 0; i < 6; i = i + 1) begin
                        d = command_addr[i];

                        $sformat(str_format, "Received command data[%0d] = %0h", i, d);
                        logger.debug(module_name, str_format);
                    end

                    if (transaction_space == REG_SPACE)
                        for (i = 0; i < 2; i = i + 1) begin
                            d = reg_data[i];

                            $sformat(str_format, "Received reg data[%0d] = %0h", i, d);
                            logger.info(module_name, str_format);
                        end
                end
            end
            PROCESS_COMMAND: begin
                if ( transaction_type == WRITE_TRANSACTION) begin
                    if (transaction_space == REG_SPACE) begin
                        reg [47:0] addr;

                        addr[47:40] = command_addr[5];
                        addr[39:32] = command_addr[4];
                        addr[31:24] = command_addr[3];
                        addr[23:16] = command_addr[2];
                        addr[15:8] = command_addr[1];
                        addr[7:0] = command_addr[0];

                        case (addr)
                            48'h600001000000: begin
                                conf_reg0 = #1 {reg_data[1], reg_data[0]};
                                print_reg0_config(conf_reg0);
                            end
                            48'h600001000001: begin
                                conf_reg1 = #1 {reg_data[1], reg_data[0]};
                                print_reg1_config(conf_reg0);
                            end
                            default: begin
                                string str_format;

                                $sformat(str_format, "Received unknown register address %h", addr);
                                logger.error(module_name, str_format);

                                $finish;
                            end
                        endcase

                        memory_state <= #1 WAIT_TRANSACTION;
                    end else begin
                        string str_format;
                        reg [47:0] addr;

                        addr[47:40] = command_addr[5];
                        addr[39:32] = command_addr[4];
                        addr[31:24] = command_addr[3];
                        addr[23:16] = command_addr[2];
                        addr[15:8] = command_addr[1];
                        addr[7:0] = command_addr[0];

                        $sformat(str_format, "Raw memory address: %0bb", addr);
                        logger.debug(module_name, str_format);

                        mem_addr[20:9] = addr[33:22];
                        mem_addr[8:3] = addr[21:16];
                        mem_addr[2:0] = addr[2:0];

                        $sformat(str_format, "Base memory address to write: %0h", mem_addr);
                        logger.info(module_name, str_format);

                        rw_counter = 8'h0;
                        memory_state <= #1 WRITE_MEMORY_DATA;
                    end
                end else begin
                    if (transaction_space == REG_SPACE) begin
                        logger.error(module_name, "Reading registers not implemnted yet");
                        $finish;
                    end else begin
                        string str_format;
                        reg [47:0] addr;

                        addr[47:40] = command_addr[5];
                        addr[39:32] = command_addr[4];
                        addr[31:24] = command_addr[3];
                        addr[23:16] = command_addr[2];
                        addr[15:8] = command_addr[1];
                        addr[7:0] = command_addr[0];

                        $sformat(str_format, "Raw memory address: %0bb", addr);
                        logger.debug(module_name, str_format);

                        mem_addr[20:9] = addr[33:22];
                        mem_addr[8:3] = addr[21:16];
                        mem_addr[2:0] = addr[2:0];

                        $sformat(str_format, "Base memory address to read: %0h", mem_addr);
                        logger.info(module_name, str_format);

                        rw_counter <= #1 8'h0;
                        delay_counter <= #1 1'b0;
                        memory_state <= #1 READ_DELAY;
                    end
                end
            end
            WRITE_MEMORY_DATA: begin
                string str_format;
                if (adq !== 8'bZ && rw_counter < burst_size) begin

                    if (rwds == 1'b0) begin
                        if (rw_counter[0] == 1'b0) begin
                            memory_area[mem_addr + rw_counter / 2][7:0] <= #1 adq;

                            $sformat(str_format, "Write byte %h to addr %h, half-word 0", adq, mem_addr + rw_counter / 2);
                            logger.debug(module_name, str_format);
                        end else begin
                            memory_area[mem_addr + rw_counter / 2][15:8] <= #1 adq;

                            $sformat(str_format, "Write byte %h to addr %h, half-word 1", adq, mem_addr + rw_counter / 2);
                            logger.debug(module_name, str_format);
                        end
                    end else begin
                        $sformat(str_format, "Skip write bute %h to addr %h, half-word %0d due to mask", adq, mem_addr + rw_counter / 2,
                                 rw_counter[0] == 1'b0);
                        logger.debug(module_name, str_format);
                    end

                    rw_counter <= #1 rw_counter_next;
                end else if (rw_counter == burst_size) begin
                    memory_state <= #1 WAIT_TRANSACTION;
                    $sformat(str_format, "Write transaction complete for addr: %0h", mem_addr);
                    logger.info(module_name, str_format);
                end
            end
            READ_DELAY:
                if (delay_counter < latency * 5'd2 - 5'd2) begin
                    if (clk)
                        delay_counter <= #1 delay_counter + 1'b1;
                end else if (!clk)
                    memory_state <= #1 READ_MEMORY_DATA;
            READ_MEMORY_DATA: begin
                if (rw_counter < burst_size) begin
                    string str_format;

                    read_address = mem_addr + rw_counter / 2;
                    if (rw_counter[0] == 1'b0) begin
                        adq_o <= #1 memory_area[read_address][7:0];
                        $sformat(str_format, "Read byte %0h from addr %0h, half-word 0", memory_area[read_address][7:0],
                                 read_address);
                        logger.debug(module_name, str_format);
                    end else begin
                        adq_o <= #1 memory_area[read_address][15:8];
                        $sformat(str_format, "Read byte %0h from addr %0h, half-word 1", memory_area[read_address][15:8],
                                 read_address);
                        logger.debug(module_name, str_format);
                    end

                    adq_o_oe <= #1 1'b1;
                    rw_counter <= #1 rw_counter_next;
                end else begin
                    adq_o_oe <= #1 1'b0;
                    logger.info(module_name, "Read transaction complete");
                    memory_state <= #1 WAIT_TRANSACTION;
                    //$finish;
                end
            end
        endcase
    end
end

endmodule
