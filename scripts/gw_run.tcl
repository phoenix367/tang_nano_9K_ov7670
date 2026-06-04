# Drives gw_sh through the Gowin synthesis / place-and-route / bitstream
# flow without needing the GUI. The flow stage is selected by the
# `STAGE` environment variable set in the wrapper script:
#   syn  - synthesis only
#   pnr  - place-and-route + bitstream generation
#   all  - both, in sequence
# The project file path is taken from the GPRJ environment variable.

set gprj $::env(GPRJ)
set stage $::env(STAGE)

puts "Opening project: $gprj"
open_project $gprj

# Placement / routing effort. route_option 2 (high-effort timing-driven routing)
# recovers ~+8 MHz on `base` and lifts fb_clk from a tight x1.04 to x1.06 vs the
# Gowin defaults -- it offsets the placement pressure the 27 MHz Wishbone bus added
# near the PSRAM hard macro. place_option 1 vs 2 converge to the same result here.
# Both default to 2 and are overridable via the PLACE_OPTION / ROUTE_OPTION env vars.
set place_opt 2
set route_opt 2
if {[info exists ::env(PLACE_OPTION)]} { set place_opt $::env(PLACE_OPTION) }
if {[info exists ::env(ROUTE_OPTION)]} { set route_opt $::env(ROUTE_OPTION) }
puts "set_option -place_option $place_opt -route_option $route_opt"
set_option -place_option $place_opt
set_option -route_option $route_opt

switch -- $stage {
    syn { run syn }
    pnr { run pnr }
    all { run all }
    default {
        puts "Unknown STAGE: $stage (expected syn|pnr|all)"
        exit 1
    }
}

exit
