// Filename: i2c_control_fsm.sv
// Created by HDL-FSM-Editor at Sat Oct  7 03:25:17 2023
module i2c_control_fsm
    #(parameter
    MAIN_CLOCK_FREQUENCY = 'd27_000_000,
    DATA_BUFFER_SIZE = 'd8,
    I2C_CLOCK_FREQUENCY = 'd100_000,
    I2C_PRESCALE_VALUE = (MAIN_CLOCK_FREQUENCY / (5 * I2C_CLOCK_FREQUENCY)) - 'd1,
    BUFFER_INDEX_WIDTH = int'($clog2(DATA_BUFFER_SIZE)),
    Prescale_reg0                  = 3'h0,
    Prescale_reg1                  = 3'h1,
    Control_reg                    = 3'h2,
    Transmit_reg                   = 3'h3,
    Receive_reg                    = 3'h3,
    Command_reg                    = 3'h4,
    Status_reg                     = 3'h4
    
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
        
        // Outputs to connect with Gowin I2C controller
        output reg tx_en,
        output reg rx_en,
        output reg [7:0] wr_data,
        output reg [2:0] wr_addr,
        input [7:0] rd_data,
        output reg [2:0] rd_addr
        
        
    );

    typedef enum {IDLE, CHECK_TRANSMIT_BYTES, ENABLE_SEND_START, PREPARE_TRANSMIT_BYTE, SEND_SLAVE_MEMORY_ADDR, SET_SLAVE_ADDRESS, START_RECV_DATA, START_SEND_DATA, STORE_DATA_STAGE, TRANSMIT_LAST_BYTE, TRANSMIT_NEXT_BYTE, TRANSMIT_SEND_MEMORY_ADDR, WAIT_COMMAND, WAIT_TRANFER_BEGIN, WAIT_TRANSFER_COMPLETE, WRITE_PRESCALE_HIGH, WRITE_PRESCALE_LOW} t_state;
    t_state state;
    reg [2:0] i2c_control_cnt;
    reg [7:0] memory_buffer[DATA_BUFFER_SIZE - 1:0];
    
    reg [BUFFER_INDEX_WIDTH - 1:0] wr_index;
    reg [BUFFER_INDEX_WIDTH - 1:0] rd_index;
    reg [2:0] transmit_context;
    reg [BUFFER_INDEX_WIDTH - 1:0] buffer_ptr;
    
    always @(posedge clk or negedge rst_n) begin: p_states
        if (rst_n == 1'b0) begin
            state <= IDLE;
            tx_en <= 1'b0;
            rx_en <= 1'b0;
            init_done <= 1'b0;
            rd_addr <= 'd0;
        end
        else begin
            // Global Actions before:
            `ifdef __ICARUS__
                $display("I2C Controller state", state);
            `endif
            // State Machine:
            case (state)
                WAIT_COMMAND: begin
                    if (store_data == 1'b1) begin
                        wr_index <= 'd1;
                        memory_buffer[0] <= data_in;
                        state <= STORE_DATA_STAGE;
                    end else if (send_data == 1'b1) begin
                        wr_data <= 8'h80;
                        wr_addr <= Control_reg;
                        tx_en <= 1'b1;
                        transmit_context <= 3'd1;
                        state <= START_SEND_DATA;
                    end else if (recv_data == 1'b1) begin
                        wr_data <= 8'h80;
                        wr_addr <= Control_reg;
                        tx_en <= 1'b1;
                        transmit_context <= 3'd3;
                        state <= START_RECV_DATA;
                    end
                end
                STORE_DATA_STAGE: begin
                    if (store_data == 1'b1) begin
                        memory_buffer[wr_index] = data_in;
                        wr_index = wr_index + 1'b1;
                    end else if (store_data == 1'b0) begin
                        state <= WAIT_COMMAND;
                    end
                end
                START_SEND_DATA: begin
                    wr_data <= {device_addr, 1'b0};
                    wr_addr <= Transmit_reg;
                    state <= SET_SLAVE_ADDRESS;
                end
                SET_SLAVE_ADDRESS: begin
                    wr_data <= 8'h90;
                    wr_addr <= Command_reg;
                    state <= ENABLE_SEND_START;
                end
                ENABLE_SEND_START: begin
                    tx_en <= 1'b0;
                    rx_en <= 1'b1;
                    rd_addr <= Status_reg;
                    state <= WAIT_TRANFER_BEGIN;
                end
                WAIT_TRANFER_BEGIN: begin
                    if ((rd_data & 8'h02) == 8'h00) begin
                    end else if (rd_data & 8'h02 ) begin
                        state <= WAIT_TRANSFER_COMPLETE;
                    end
                end
                WAIT_TRANSFER_COMPLETE: begin
                    if ((rd_data & 8'h02) == 8'h00) begin
                        if (transmit_context == 3'd1) begin
                            rx_en <= 1'd0;
                            tx_en <= 1'd1;
                            buffer_ptr <= 'd1;
                            wr_data <= memory_buffer[0];
                            wr_addr <= Transmit_reg;
                            state <= SEND_SLAVE_MEMORY_ADDR;
                        end else if (transmit_context == 3'd2) begin
                            rx_en <= 1'd0;
                            tx_en <= 1'd0;
                            state <= CHECK_TRANSMIT_BYTES;
                        end
                    end
                end
                SEND_SLAVE_MEMORY_ADDR: begin
                    wr_data <= 8'h10;
                    wr_addr <= Command_reg;
                    transmit_context <= 3'd2;
                    state <= TRANSMIT_SEND_MEMORY_ADDR;
                end
                TRANSMIT_SEND_MEMORY_ADDR: begin
                    tx_en <= 1'b0;
                    rx_en <= 1'b1;
                    rd_addr <= Status_reg;
                    state <= WAIT_TRANFER_BEGIN;
                end
                CHECK_TRANSMIT_BYTES: begin
                    if (buffer_ptr >= wr_index) begin
                        state <= WAIT_COMMAND;
                    end else if (buffer_ptr < wr_index) begin
                        tx_en <= 1'b1;
                        wr_data <= memory_buffer[buffer_ptr];
                        wr_addr <= Transmit_reg;
                        state <= PREPARE_TRANSMIT_BYTE;
                    end
                end
                PREPARE_TRANSMIT_BYTE: begin
                    if (buffer_ptr < wr_index - 'd1) begin
                        wr_data <= 8'h10;
                        wr_addr <= Command_reg;
                        state <= TRANSMIT_NEXT_BYTE;
                    end else if (buffer_ptr == wr_index - 'd1) begin
                        wr_data <= 8'h50;
                        wr_addr <= Command_reg;
                        state <= TRANSMIT_LAST_BYTE;
                    end
                end
                TRANSMIT_NEXT_BYTE: begin
                    buffer_ptr <= buffer_ptr + 1'b1;
                    tx_en <= 1'b0;
                    state <= ENABLE_SEND_START;
                end
                TRANSMIT_LAST_BYTE: begin
                    buffer_ptr <= buffer_ptr + 1'b1;
                    tx_en <= 1'b0;
                    state <= ENABLE_SEND_START;
                end
                START_RECV_DATA: begin
                    wr_data <= {device_addr, 1'b0};
                    wr_addr <= Transmit_reg;
                    state <= SET_SLAVE_ADDRESS;
                end
                IDLE: begin
                    tx_en <= 1'b1;
                    wr_data <= I2C_PRESCALE_VALUE[7:0];
                    wr_addr <= Prescale_reg0;
                    state <= WRITE_PRESCALE_LOW;
                end
                WRITE_PRESCALE_LOW: begin
                    wr_data <= I2C_PRESCALE_VALUE[15:8];
                    wr_addr <= Prescale_reg1;
                    state <= WRITE_PRESCALE_HIGH;
                end
                WRITE_PRESCALE_HIGH: begin
                    init_done <= 1'b1;
                    tx_en <= 1'b0;
                    rx_en <= 1'b0;
                    state <= WAIT_COMMAND;
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
            CHECK_TRANSMIT_BYTES:
                ;
            ENABLE_SEND_START:
                ;
            IDLE:
                ;
            PREPARE_TRANSMIT_BYTE: begin
                `ifdef __ICARUS__
                    $finish;
                `endif
            end
            SEND_SLAVE_MEMORY_ADDR:
                ;
            SET_SLAVE_ADDRESS:
                ;
            START_RECV_DATA:
                ;
            START_SEND_DATA:
                ;
            STORE_DATA_STAGE:
                ;
            TRANSMIT_LAST_BYTE:
                ;
            TRANSMIT_NEXT_BYTE:
                ;
            TRANSMIT_SEND_MEMORY_ADDR:
                ;
            WAIT_COMMAND:
                ;
            WAIT_TRANFER_BEGIN:
                ;
            WAIT_TRANSFER_COMPLETE:
                ;
            WRITE_PRESCALE_HIGH:
                ;
            WRITE_PRESCALE_LOW:
                ;
            default:
                ;
        endcase
    end
    // Global Actions combinatorial:
    `ifdef __ICARUS__
    initial begin
        $dumpvars(0, state);
    end
    `endif
endmodule
