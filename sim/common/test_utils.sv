`include "svlogger.sv"

`define TEST_FAIL \
    begin \
        $display("-----------"); \
        $display("Test failed"); \
        $display("-----------"); \
        $finish_and_return(1);\
    end

`define TEST_PASS \
    begin \
        $display("-----------"); \
        $display("Test passed"); \
        $display("-----------"); \
        $finish_and_return(0);\
    end
