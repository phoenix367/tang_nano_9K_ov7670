#!/usr/bin/env bash
# Run Gowin gw_sh with the LD_LIBRARY_PATH/LD_PRELOAD env that
# Gowin_V1.9.12.x ships with for Linux (matches the wrapper printed by
# the IDE launcher). Honours these env vars:
#   GOWIN_PATH - Gowin install root (the directory that contains IDE/).
#                Required.
#   GPRJ       - Absolute path to the .gprj project file. Required.
#   STAGE      - syn | pnr | all. Defaults to all.

set -euo pipefail

if [[ -z "${GOWIN_PATH:-}" ]]; then
    echo "GOWIN_PATH not set; point it at the Gowin install (e.g.\
 /mnt/data/Gowin_V1.9.12.02_SP2_linux)" >&2
    exit 1
fi
if [[ -z "${GPRJ:-}" ]]; then
    echo "GPRJ not set; point it at the .gprj project file" >&2
    exit 1
fi
STAGE="${STAGE:-all}"

# Resolve gw_run.tcl path before cd'ing into GOWIN_PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL_SCRIPT="$SCRIPT_DIR/gw_run.tcl"

cd "$GOWIN_PATH"
export LD_LIBRARY_PATH="./IDE/lib"
export LD_PRELOAD="/lib/x86_64-linux-gnu/libstdc++.so.6 /lib/x86_64-linux-gnu/libfreetype.so"
export GPRJ STAGE
exec ./IDE/bin/gw_sh "$TCL_SCRIPT"
