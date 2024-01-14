`ifndef __PSRAM_UTILS_VH__
`define __PSRAM_UTILS_VH__

package PSRAM_Utilities;

    function reg [5:0] burst_delay(input int burst);
        case (burst)
             16: burst_delay = 6'd15;
             32: burst_delay = 6'd19;
             64: burst_delay = 6'd27;
            128: burst_delay = 6'd43;
            default: $error("%m Invalid memory burst value");
        endcase
    endfunction

endpackage
`endif /* __PSRAM_UTILS_VH__ */
