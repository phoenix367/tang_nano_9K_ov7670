`include "timescale.v"
`include "camera_control_defs.vh"

module i2c_control_fsm
    #(parameter
    MAIN_CLOCK_FREQUENCY = 'd27_000_000,
    DATA_BUFFER_SIZE = 'd8,
    I2C_CLOCK_FREQUENCY = 'd100_000
    )
    (
        input clk, 
        input rst_n, 
        input [6:0] device_addr,
        output reg init_done,
        input store_data,
        input load_data,
        input send_data,
        input recv_data,
        input [7:0] data_in,
        output reg device_rdy,
        output reg error_o,
        
        // Outputs to connect with Gowin I2C controller
        output reg tx_en,
        output reg rx_en,
        output reg [7:0] wr_data,
        output reg [2:0] wr_addr,
        input [7:0] rd_data,
        output reg [2:0] rd_addr,
        input cmd_ack_i
        
    );

    reg [4:0] state;

    localparam
        Prescale_reg0                  = 3'h0,
        Prescale_reg1                  = 3'h1,
        Control_reg                    = 3'h2,
        Transmit_reg                   = 3'h3,
        Receive_reg                    = 3'h3,
        Command_reg                    = 3'h4,
        Status_reg                     = 3'h4;

    localparam
        IDLE = 0,
        CHECK_TRANSMIT_BYTES = 1,
        ENABLE_SEND_START = 2,
        PREPARE_TRANSMIT_BYTE = 3,
        SEND_SLAVE_MEMORY_ADDR = 4,
        SET_SLAVE_ADDRESS = 5,
        START_RECV_DATA = 6,
        START_SEND_DATA = 7,
        STORE_DATA_STAGE = 8,
        TRANSMIT_LAST_BYTE = 9,
        TRANSMIT_NEXT_BYTE = 10,
        TRANSMIT_SEND_MEMORY_ADDR = 11,
        WAIT_COMMAND = 12,
        WAIT_TRANFER_BEGIN = 13,
        WAIT_TRANSFER_COMPLETE = 14,
        WRITE_PRESCALE_HIGH = 15,
        WRITE_PRESCALE_LOW = 16,
        WAIT_WE_ACK = 17,
        PRE_TRANSMIT_BYTE = 18;

    localparam
        I2C_PRESCALE_VALUE = (MAIN_CLOCK_FREQUENCY / (5 * I2C_CLOCK_FREQUENCY)) - 'd1,
        BUFFER_INDEX_WIDTH = int'($clog2(DATA_BUFFER_SIZE));

    localparam
        STATUS_REG_RX_ACK   = 8'b10000000,
        STATUS_REG_BUS_BUSY = 8'b01000000,
        STATUS_REG_AL       = 8'b00100000,
        STATUS_REG_TIP      = 8'b00000010,
        STATUS_REG_INT      = 8'b00000001;

    // Control register flags
    localparam
        CTRL_REG_CORE_EN = 8'b10000000,     // Core enable
        CTRL_REG_INT_EN  = 8'b01000000;     // Interrupt pin enable

    reg [2:0] i2c_control_cnt;
    reg [7:0] memory_buffer[DATA_BUFFER_SIZE - 1:0];
    
    reg [BUFFER_INDEX_WIDTH - 1:0] wr_index;
    reg [BUFFER_INDEX_WIDTH - 1:0] rd_index;
    reg [2:0] transmit_context;
    reg [BUFFER_INDEX_WIDTH - 1:0] buffer_ptr;
    
    `ifdef __ICARUS__
    initial begin
            $monitor("t=%d, DEBUG i2c_control_fsm; I2C Controller state = %d", $time, state);
    end
    `endif

    initial begin
        device_rdy = 1'b0;
        error_o <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin: p_states
        if (rst_n == 1'b0) begin
            state <= IDLE;
            tx_en <= 1'b0;
            rx_en <= 1'b0;
            init_done <= 1'b0;
            rd_addr <= 'd0;
            error_o <= 1'b0;
        end else begin
            // Global Actions before:
            // State Machine:
            case (state)
                WAIT_COMMAND: begin
                    if (store_data == 1'b1) begin
                        wr_index <= `WRAP_SIM(#1) 'd1;
                        memory_buffer[0] <= `WRAP_SIM(#1) data_in;
                        state <= `WRAP_SIM(#1) STORE_DATA_STAGE;
                        error_o <= 1'b0;
                        `WRAP_SIM($display("t=%d, DEBUG i2c_control_fsm; Store byte %0h at address %0d", $time, data_in, 0));
                    end else if (send_data == 1'b1) begin
                        wr_data <= `WRAP_SIM(#1) CTRL_REG_CORE_EN;
                        wr_addr <= `WRAP_SIM(#1) Control_reg;
                        tx_en <= `WRAP_SIM(#1) 1'b1;
                        transmit_context <= `WRAP_SIM(#1) 3'd1;

                        `WRAP_SIM($display("t=%d, DEBUG i2c_control_fsm; Switch to send data stage", $time));
                        state <= WAIT_WE_ACK;
                        error_o <= 1'b0;
                    end else if (recv_data == 1'b1) begin
                        wr_data <= `WRAP_SIM(#1) 8'h80;
                        wr_addr <= `WRAP_SIM(#1) Control_reg;
                        tx_en <= `WRAP_SIM(#1) 1'b1;
                        transmit_context <= `WRAP_SIM(#1) 3'd4;

                        state <= `WRAP_SIM(#1) START_RECV_DATA;
                        error_o <= 1'b0;
                    end
                end
                STORE_DATA_STAGE: begin
                    if (store_data == 1'b1) begin
                        memory_buffer[wr_index] = `WRAP_SIM(#1) data_in;
                        `WRAP_SIM($display("t=%d, DEBUG i2c_control_fsm; Store byte %0h at address %0d", 
                                  $time, data_in, wr_index));

                        wr_index = `WRAP_SIM(#1) wr_index + 1'b1;
                    end else if (store_data == 1'b0) begin
                        state <= `WRAP_SIM(#1) WAIT_COMMAND;
                    end
                end
                WAIT_WE_ACK: begin
                    if (cmd_ack_i)
                        state <= `WRAP_SIM(#1) START_SEND_DATA;
                end
                START_SEND_DATA: begin
                    wr_data <= `WRAP_SIM(#1) {device_addr, 1'b0};
                    wr_addr <= `WRAP_SIM(#1) Transmit_reg;
                    if (cmd_ack_i)
                        state <= `WRAP_SIM(#1) SET_SLAVE_ADDRESS;
                end
                SET_SLAVE_ADDRESS: begin
                    wr_data <= `WRAP_SIM(#1) 8'h90;
                    wr_addr <= `WRAP_SIM(#1) Command_reg;
                    if (cmd_ack_i)
                        state <= `WRAP_SIM(#1) ENABLE_SEND_START;
                end
                ENABLE_SEND_START: begin
                    tx_en <= `WRAP_SIM(#1) 1'b0;
                    rx_en <= `WRAP_SIM(#1) 1'b1;
                    rd_addr <= `WRAP_SIM(#1) Status_reg;
                    if (cmd_ack_i)
                        state <= `WRAP_SIM(#1) WAIT_TRANFER_BEGIN;
                end
                WAIT_TRANFER_BEGIN: begin
                    if ((rd_data & STATUS_REG_TIP) == 8'h00) begin
                        //$finish;
                    //end else if (rd_data & 8'h02 ) begin
                        //if (transmit_context == 3'd1) begin
                        if (cmd_ack_i) begin
                            state <= `WRAP_SIM(#1) WAIT_TRANSFER_COMPLETE;
                            `WRAP_SIM($display("t=%d, DEBUG i2c_control_fsm; Wait cycle complete, context = %0d", 
                                          $time, transmit_context));
                            rx_en <= `WRAP_SIM(#1) 1'd0;
                            tx_en <= `WRAP_SIM(#1) 1'd0;
                        end
                        //end
                        //else if((rd_data & STATUS_REG_BUS_BUSY) == 8'h00) begin
                        //    state <= `WRAP_SIM(#1) WAIT_TRANSFER_COMPLETE;
                        //    `WRAP_SIM($display("t=%d, DEBUG i2c_control_fsm; Wait cycle complete, context = %0d", 
                         //                 $time, transmit_context));
                        //end
                    end
                end
                WAIT_TRANSFER_COMPLETE: begin
                    if (transmit_context == 3'd1) begin
                        rx_en <= `WRAP_SIM(#1) 1'd0;
                        tx_en <= `WRAP_SIM(#1) 1'd1;
                        buffer_ptr <= `WRAP_SIM(#1) 'd1;
                        wr_data <= `WRAP_SIM(#1) memory_buffer[0];
                        wr_addr <= `WRAP_SIM(#1) Transmit_reg;
                        if (cmd_ack_i) begin
                            state <= `WRAP_SIM(#1) SEND_SLAVE_MEMORY_ADDR;
                            `WRAP_SIM($display("t=%d, DEBUG i2c_control_fsm; Set slave memory addr to %0h", 
                                          $time, memory_buffer[0]));
                        end
                    end else if (transmit_context == 3'd2) begin
                        rx_en <= `WRAP_SIM(#1) 1'd1;
                        tx_en <= `WRAP_SIM(#1) 1'd0;
                        state <= `WRAP_SIM(#1) CHECK_TRANSMIT_BYTES;
                    end else if (transmit_context == 3'd3) begin
                        rx_en <= `WRAP_SIM(#1) 1'd0;
                        tx_en <= `WRAP_SIM(#1) 1'd0;
                        state <= `WRAP_SIM(#1) SEND_SLAVE_MEMORY_ADDR;
                    end
                end
                SEND_SLAVE_MEMORY_ADDR: begin
                    wr_data <= `WRAP_SIM(#1) 8'h10;
                    wr_addr <= `WRAP_SIM(#1) Command_reg;
                    transmit_context <= `WRAP_SIM(#1) 3'd2;

                    if (cmd_ack_i) begin
                        state <= `WRAP_SIM(#1) TRANSMIT_SEND_MEMORY_ADDR;
                        `WRAP_SIM($display("t=%d, DEBUG i2c_control_fsm; Send slave memory addr", 
                                      $time));
                    end
                end
                TRANSMIT_SEND_MEMORY_ADDR: begin
                    tx_en <= `WRAP_SIM(#1) 1'b0;
                    rx_en <= `WRAP_SIM(#1) 1'b1;
                    rd_addr <= `WRAP_SIM(#1) Status_reg;
                    if (cmd_ack_i) begin
                        state <= `WRAP_SIM(#1) WAIT_TRANFER_BEGIN;
                        `WRAP_SIM($display("t=%d, DEBUG i2c_control_fsm; Start wait cycle for memory addr", 
                                      $time));
                    end
                end
                CHECK_TRANSMIT_BYTES: begin
                    if (buffer_ptr >= wr_index) begin
                        if ((rd_data & STATUS_REG_BUS_BUSY) == 8'h00) begin
                            if (cmd_ack_i) begin
                                rx_en <= `WRAP_SIM(#1) 1'b0;
                                state <= `WRAP_SIM(#1) WAIT_COMMAND;

                                if ((rd_data & STATUS_REG_RX_ACK) != 8'h00)
                                    error_o <= 1'b1;
                            end
                        end
                    end else if (buffer_ptr < wr_index) begin
                        tx_en <= `WRAP_SIM(#1) 1'b1;
                        wr_data <= `WRAP_SIM(#1) memory_buffer[buffer_ptr];
                        wr_addr <= `WRAP_SIM(#1) Transmit_reg;
                        if (cmd_ack_i)
                            state <= `WRAP_SIM(#1) PREPARE_TRANSMIT_BYTE;
                    end
                end
                PREPARE_TRANSMIT_BYTE: begin
                    if (buffer_ptr < wr_index - 'd1) begin
                        wr_data <= `WRAP_SIM(#1) 8'h10;
                        wr_addr <= `WRAP_SIM(#1) Command_reg;
                        if (cmd_ack_i)
                            state <= `WRAP_SIM(#1) TRANSMIT_NEXT_BYTE;
                    end else if (buffer_ptr == wr_index - 'd1) begin
                        wr_data <= `WRAP_SIM(#1) 8'h50;
                        wr_addr <= `WRAP_SIM(#1) Command_reg;
                        if (cmd_ack_i)
                            state <= `WRAP_SIM(#1) TRANSMIT_LAST_BYTE;
                    end
                end
                TRANSMIT_NEXT_BYTE: begin
                    buffer_ptr <= `WRAP_SIM(#1) buffer_ptr + 1'b1;
                    tx_en <= `WRAP_SIM(#1) 1'b0;
                    state <= `WRAP_SIM(#1) ENABLE_SEND_START;
                end
                TRANSMIT_LAST_BYTE: begin
                    buffer_ptr <= `WRAP_SIM(#1) buffer_ptr + 1'b1;
                    tx_en <= `WRAP_SIM(#1) 1'b0;
                    state <= `WRAP_SIM(#1) ENABLE_SEND_START;
                end
                START_RECV_DATA: begin
                    wr_data <= `WRAP_SIM(#1) {device_addr, 1'b0};
                    wr_addr <= `WRAP_SIM(#1) Transmit_reg;
                    state <= `WRAP_SIM(#1) SET_SLAVE_ADDRESS;
                end
                IDLE: begin
                    tx_en <= `WRAP_SIM(#1) 1'b1;
                    wr_data <= `WRAP_SIM(#1) I2C_PRESCALE_VALUE[7:0];
                    wr_addr <= `WRAP_SIM(#1) Prescale_reg0;
                    if (cmd_ack_i)
                        state <= `WRAP_SIM(#1) WRITE_PRESCALE_LOW;
                end
                WRITE_PRESCALE_LOW: begin
                    wr_data <= `WRAP_SIM(#1) I2C_PRESCALE_VALUE[15:8];
                    wr_addr <= `WRAP_SIM(#1) Prescale_reg1;
                    if (cmd_ack_i)
                        state <= `WRAP_SIM(#1) WRITE_PRESCALE_HIGH;
                end
                WRITE_PRESCALE_HIGH: begin
                    tx_en <= `WRAP_SIM(#1) 1'b0;
                    rx_en <= `WRAP_SIM(#1) 1'b0;

                    if (cmd_ack_i) begin
                        state <= `WRAP_SIM(#1) WAIT_COMMAND;
                        init_done <= `WRAP_SIM(#1) 1'b1;
                    end
                end
                default:
                    ;
            endcase
            // Global Actions after:
            
        end
    end
    always @(state) begin: p_state_actions
        // State Actions:
        case (state)
            WAIT_COMMAND: device_rdy = 1'b1;
            default:
                device_rdy = 1'b0;
        endcase
    end
    // Global Actions combinatorial:
    `ifdef __ICARUS__
    initial begin
        $dumpvars(0, state, rx_en, tx_en, rd_addr, rd_data, wr_addr, wr_data);
    end
    `endif
endmodule
