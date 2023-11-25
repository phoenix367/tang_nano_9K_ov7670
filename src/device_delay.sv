`include "camera_control_defs.vh"

module device_delay #(
    parameter MAIN_CLOCK_FREQUENCY = 'd27_000_000,
              DELAY_MS = 'd10
) 
(
    input clk_i,
    input rst_n,
    input syn_rst,
    output reg delay_done
);

localparam MAX_COUNTER_VALUE = (MAIN_CLOCK_FREQUENCY / 1000 * DELAY_MS);
localparam COUNTER_WIDTH = int'($clog2(MAX_COUNTER_VALUE));

reg [COUNTER_WIDTH - 1:0] counter;

typedef enum { IDLE, COUNT, DONE } DELAY_STATES;
DELAY_STATES state;

task reset_state();
    counter <= `WRAP_SIM(#1) 'd0;
    state <= `WRAP_SIM(#1) IDLE;
endtask

initial begin
    reset_state();
end

always @(posedge clk_i or negedge rst_n) begin
    if (!rst_n) begin
        reset_state();
    end else begin
        if (syn_rst)
            reset_state();
        else
            case (state)
                IDLE: begin
                    counter <= `WRAP_SIM(#1) 'd0;
                    state <= `WRAP_SIM(#1) COUNT;
                    `WRAP_SIM($display("t=%d, DEBUG device_delay; Start delay of %0d ms", $time, DELAY_MS));
                end
                COUNT: begin
                    if (counter < MAX_COUNTER_VALUE)
                        counter <= `WRAP_SIM(#1) counter + 1'b1;
                    else begin
                        state <= `WRAP_SIM(#1) DONE;
                        `WRAP_SIM($display("t=%d, DEBUG device_delay; Delay is done", $time));
                    end
                end
            endcase
    end
end

always @(state) begin
    if (state == DONE)
        delay_done = `WRAP_SIM(#1) 1'b1;
    else
        delay_done = `WRAP_SIM(#1) 1'b0;
end

endmodule
