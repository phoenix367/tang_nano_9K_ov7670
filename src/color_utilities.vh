`ifndef __COLOR_UTILITIES_VH__
`define __COLOR_UTILITIES_VH__

package ColorUtilities;
    function bit [15:0] convert_RGB24_BGR565
    (
        input bit [7:0] R,
        input bit [7:0] G,
        input bit [7:0] B
    );
        bit [4:0] r_value, b_value;
        bit [5:0] g_value;

        r_value = R >> 3;
        g_value = G >> 2;
        b_value = B >> 3;

        convert_RGB24_BGR565 = {r_value, g_value, b_value};
    endfunction

    // This function returns 16-bit color values for first ten
    // SMPTE ECR 1-1978 color bars
    function logic [15:0] get_rgb_color(input logic [3:0] bar_index);
        case (bar_index)
            0: 
                get_rgb_color = convert_RGB24_BGR565(8'd104, 8'd104, 8'd104); // 40% Gray
            1: 
                get_rgb_color = convert_RGB24_BGR565(8'd180, 8'd180, 8'd180); // 75% White 
            2: 
                get_rgb_color = convert_RGB24_BGR565(8'd180, 8'd180, 8'd16); // 75% Yellow
            3: 
                get_rgb_color = convert_RGB24_BGR565(8'd16, 8'd180, 8'd180); // 75% Cyan
            4:
                get_rgb_color = convert_RGB24_BGR565(8'd16, 8'd180, 8'd16); // 75% Green
            5:
                get_rgb_color = convert_RGB24_BGR565(8'd180, 8'd16, 8'd180); // 75% Magenta
            6:
                get_rgb_color = convert_RGB24_BGR565(8'd180, 8'd16, 8'd16); // 75% Red
            7:
                get_rgb_color = convert_RGB24_BGR565(8'd16, 8'd16, 8'd180); // 75% Blue
            8:
                get_rgb_color = convert_RGB24_BGR565(8'd16, 8'd16, 8'd16); // 75% Black
            9:
                get_rgb_color = convert_RGB24_BGR565(8'd235, 8'd235, 8'd235); // 100% White
            default:
                get_rgb_color = 16'h0000;
        endcase
    endfunction

endpackage

`endif /* __COLOR_UTILITIES_VH__ */
