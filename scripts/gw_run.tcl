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
