// distributed under the mit license
// https://opensource.org/licenses/mit-license.php

`ifndef SVLOGGER
`define SVLOGGER

`define SVL_VERBOSE_OFF 0
`define SVL_VERBOSE_DEBUG 1
`define SVL_VERBOSE_INFO 2
`define SVL_VERBOSE_WARNING 3
`define SVL_VERBOSE_CRITICAL 4
`define SVL_VERBOSE_ERROR 5

`define SVL_ROUTE_TERM 1
`define SVL_ROUTE_FILE 2
`define SVL_ROUTE_ALL 3

`define INITIALIZE_LOGGER \
    string module_name; \
    DataLogger #(.name(MODULE_NAME), .verbosity(LOG_LEVEL)) logger(); \
    \
    initial begin \
        $sformat(module_name, "%m"); \
    end


module DataLogger #(
    parameter
    ////////////////////////////////////////////
    // Name of the module printed in the console
    // and/or the log file name
    name = "",

    ///////////////////////////////////
    // Verbosity level of the instance:
    //   - 0: no logging
    //   - 1: debug/info/warning/critical/error
    //   - 2: info/warning/critical/error
    //   - 3: warning/critical/error
    //   - 4: critical/error
    //   - 5: error
    verbosity = `SVL_VERBOSE_INFO,

    ///////////////////////////////////////////////////////
    // Define if log in the console, in a log file or both:
    //   - 1: console only
    //   - 2: log file only
    //   - 3: console and log file
    route = `SVL_ROUTE_TERM
)(
);

// pointer to log file
integer f;

// color codes:
// BLACK      "\033[1;30m"
// RED        "\033[1;31m"
// GREEN      "\033[1;32m"
// BROWN      "\033[1;33m"
// BLUE       "\033[1;34m"
// PINK       "\033[1;35m"
// CYAN       "\033[1;36m"
// WHITE      "\033[1;37m"
// NC         "\033[0m"

initial begin
    if (route==`SVL_ROUTE_FILE || route==`SVL_ROUTE_ALL) begin
        f = $fopen({name, ".txt"},"a");
    end
end

// Internal function to log into console and/or log file
// Internal use only
task _log_text(string text);
begin
    string t_text;
    if (route==`SVL_ROUTE_TERM || route==`SVL_ROUTE_ALL) begin
        $display(text);
    end
    if (route==`SVL_ROUTE_FILE || route==`SVL_ROUTE_ALL) begin
        $sformat(t_text, "%s\n", text);
        $fwrite(f, t_text);
    end
end
endtask

// Just write a message without any formatting neither time printed
// Could be used for further explanation of a previous debug/info ...
task msg(string text);
begin
    _log_text(text);
end
endtask

// Print a debug message, in white
task debug(string module_name, string text);
begin
    if (verbosity<`SVL_VERBOSE_INFO && verbosity>`SVL_VERBOSE_OFF) begin
        string t_text;
        $sformat(t_text, "%s: DEBUG: (@ %0t) %s", module_name, $realtime, text);
        _log_text(t_text);
    end
end
endtask

// Print an info message, in blue
task info(string module_name, string text);
begin
    if (verbosity<`SVL_VERBOSE_WARNING && verbosity>`SVL_VERBOSE_OFF) begin
        string t_text;
        $sformat(t_text, "%s: INFO: (@ %0t) %s", module_name, $realtime, text);
        _log_text(t_text);
    end
end
endtask

// Print a warning message, in yellow
task warning(string module_name, string text);
begin
    if (verbosity<`SVL_VERBOSE_CRITICAL && verbosity>`SVL_VERBOSE_OFF) begin
        string t_text;
        $sformat(t_text, "%s: WARNING: (@ %0t) %s", module_name, $realtime, text);
        _log_text(t_text);
    end
end
endtask

// Print a critical message, in pink
task critical(string module_name, string text);
begin
    if (verbosity<`SVL_VERBOSE_ERROR && verbosity>`SVL_VERBOSE_OFF) begin
        string t_text;
        $sformat(t_text, "%s: CRITICAL: (@ %0t) %s", module_name, $realtime, text);
        _log_text(t_text);
    end
end
endtask

// Print an error message, in red
task error(string module_name, string text);
begin
    if (verbosity<`SVL_VERBOSE_ERROR+1 && verbosity>`SVL_VERBOSE_OFF) begin
        string t_text;
        $sformat(t_text, "%s: ERROR: (@ %0t) %s", module_name, $realtime, text);
        _log_text(t_text);
    end
end
endtask

endmodule

`endif
