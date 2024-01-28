`ifdef __ICARUS__
`include "timescale.v"
`include "camera_control_defs.vh"
`else
`include "../timescale.v"
`include "../camera_control_defs.vh"
`endif

`ifdef __ICARUS__
`include "svlogger.sv"
`endif

module BufferController
#(
`ifdef __ICARUS__
        parameter MODULE_NAME = "",
        parameter LOG_LEVEL = `SVL_VERBOSE_INFO
`endif
)
(
    input clk,
    input reset_n,
    input write_rq_rdy,
    input finalize_wr,
    input read_rq_rdy,
    input finalize_rd,
    output buffer_id_valid,
    output reg [1:0] buffer_id
);

// Logger initialization
`ifdef __ICARUS__
    `INITIALIZE_LOGGER
`endif

    import BufferControllerTypes::*;

    localparam NUM_BUFFERS = 'd3;

    function logic[1:0] get_next(input logic[1:0] current_pos);
        if (current_pos === NUM_BUFFERS - 1)
            get_next = 'd0;
        else
            get_next = current_pos + 'd1;
    endfunction

    BufferStates buffer_states[NUM_BUFFERS - 1:0];
    reg [1:0] buffer_read_ptr;
    reg [1:0] buffer_write_ptr;

    typedef enum logic[1:0] {
        WRITE_IDLE,
        CHECK_STEP,
        WRITE_SELECT
    } write_state_t;

    typedef enum logic[1:0] {
        READ_IDLE,
        READ_CHECK_STEP,
        READ_SELECT
    } read_state_t;

    write_state_t write_state;
    read_state_t read_state;

    assign buffer_id_valid = ((write_state === WRITE_SELECT) && write_rq_rdy) ||
                             ((read_state === READ_SELECT) && read_rq_rdy);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            integer i;

            for (i = 0; i !== NUM_BUFFERS; i = i + 1'b1)
                buffer_states[i] <= `WRAP_SIM(#1) BUFFER_AVAILABLE;

            buffer_id <= `WRAP_SIM(#1) 'd0;
            buffer_read_ptr <= `WRAP_SIM(#1) 'd0;
            buffer_write_ptr <= `WRAP_SIM(#1) 'd0;

            write_state <= `WRAP_SIM(#1) WRITE_IDLE;
            read_state <= `WRAP_SIM(#1) READ_IDLE;
        end else begin
            if (finalize_wr) begin
                case (write_state)
                    WRITE_SELECT: begin
`ifdef __ICARUS__
                        string str;
`endif

                        buffer_states[buffer_write_ptr] <= `WRAP_SIM(#1) BUFFER_UPDATED;
                        write_state <= `WRAP_SIM(#1) WRITE_IDLE;

`ifdef __ICARUS__
                        $sformat(str, "Write buffer %0d released", buffer_write_ptr);
                        logger.info(module_name, str);
`endif
                    end
                endcase
            end else if (write_rq_rdy) begin
                case (write_state)
                    WRITE_IDLE: begin
                        buffer_write_ptr <= `WRAP_SIM(#1) get_next(buffer_write_ptr);
                        write_state <= `WRAP_SIM(#1) CHECK_STEP;
                    end
                    CHECK_STEP: begin
`ifdef __ICARUS__
                        string str;
`endif

                        if (buffer_states[buffer_write_ptr] === BUFFER_READ_BUSY)
                            write_state <= `WRAP_SIM(#1) WRITE_IDLE;
                        else begin
                            write_state <= `WRAP_SIM(#1) WRITE_SELECT;
                            buffer_id <= `WRAP_SIM(#1) buffer_write_ptr;
                            buffer_states[buffer_write_ptr] <= `WRAP_SIM(#1) BUFFER_WRITE_BUSY;

`ifdef __ICARUS__
                            $sformat(str, "Select write buffer %0d", buffer_write_ptr);
                            logger.info(module_name, str);
`endif
                        end
                    end
                    WRITE_SELECT: 
                        // Do nothing
                        ;
                endcase
            end else if (finalize_rd) begin
                case (read_state)
                    READ_SELECT: begin
`ifdef __ICARUS__
                        string str;
`endif

                        buffer_states[buffer_read_ptr] <= `WRAP_SIM(#1) BUFFER_DISPLAYED;
                        read_state <= `WRAP_SIM(#1) READ_IDLE;

`ifdef __ICARUS__
                        $sformat(str, "Read buffer %0d released", buffer_read_ptr);
                        logger.info(module_name, str);
`endif
                    end
                endcase
            end else if (read_rq_rdy) begin
                case (read_state)
                    READ_IDLE: begin
                    end
                    READ_CHECK_STEP: begin
                    end
                    READ_SELECT:
                        // Do nothing
                        ;
                endcase
            end
        end
    end

endmodule
