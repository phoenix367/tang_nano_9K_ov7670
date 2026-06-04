# Formal verification targets (yosys). Registered only when a yosys binary was
# found (see the top-level CMakeLists). Each proof reads the RTL with -DFORMAL so
# the `ifdef FORMAL properties (embedded directly in the src modules) compile in,
# then proves the assertions. No separate wrapper .sv files -- every module
# carries its own properties.
#
# Proof flow (sequential-capable; works for combinational modules too):
#   flatten        : sat needs a single module
#   async2sync     : convert $adff (async reset) so sat can import the FFs
#   set-init-zero  : model power-up (FFs start 0, matching reset)
#   tempinduct     : unbounded proof by k-induction with the built-in SAT solver
#   -verify        : non-zero exit on a failed proof  -> ctest pass/fail
#
# ctest labels: `formal` plus the proof name -> `ctest -L formal`.

# register_formal(<name> <top> SOURCES <a.sv> [b.sv ...] [CHPARAM "<p> <v>" ...])
#   CHPARAM entries become `chparam -set <p> <v> <top>` (e.g. to pick the arbiter
#   width); the embedded properties otherwise prove at the modules' real params.
function(register_formal NAME TOP)
    cmake_parse_arguments(RF "" "" "SOURCES;CHPARAM" ${ARGN})

    set(YS_FILE "${CMAKE_CURRENT_BINARY_DIR}/${NAME}.ys")
    set(YS_SCRIPT "")
    foreach (SRC IN LISTS RF_SOURCES)
        string(APPEND YS_SCRIPT "read_verilog -sv -formal -DFORMAL -I ${SRC_FOLDER} ${SRC}\n")
    endforeach()
    foreach (CP IN LISTS RF_CHPARAM)            # "param value" -> chparam -set param value top
        string(REPLACE " " ";" CP_PARTS "${CP}")
        list(GET CP_PARTS 0 CP_NAME)
        list(GET CP_PARTS 1 CP_VAL)
        string(APPEND YS_SCRIPT "chparam -set ${CP_NAME} ${CP_VAL} ${TOP}\n")
    endforeach()
    string(APPEND YS_SCRIPT "prep -top ${TOP} -flatten\n")
    string(APPEND YS_SCRIPT "async2sync\n")
    string(APPEND YS_SCRIPT "chformal -cover -remove\n")  # sat consumes asserts only
    string(APPEND YS_SCRIPT "sat -tempinduct -prove-asserts -verify -set-init-zero\n")
    file(WRITE "${YS_FILE}" "${YS_SCRIPT}")

    add_test(NAME "formal_${NAME}" COMMAND "${YOSYS}" -s "${YS_FILE}")
    set_tests_properties("formal_${NAME}" PROPERTIES LABELS "formal;${NAME}")
endfunction()

# Wishbone interconnect decode/mux (combinational, exhaustive).
register_formal(wb_interconnect wb_interconnect
    SOURCES "${SRC_FOLDER}/modbus/wb_interconnect.sv")

# Round-robin arbiter (sequential): mutual exclusion + grant/req/enable/select
# invariants, by k-induction. Properties embedded in src/arbiter.v; width fixed to
# 4 here (the deployed PSRAM arbiter is width 2, a subcase).
register_formal(arbiter arbiter
    SOURCES "${SRC_FOLDER}/arbiter.v"
    CHPARAM "width 4" "select_width 2")

# Health watchdog (sequential): hang stickiness + consistency + arm ordering. The
# invariants are scale-invariant, so they prove at the shipped STARTUP/TIMEOUT
# counters -- no parameter shrink needed. Pulls in the CDC_Bit_Synchronizer.
register_formal(watchdog watchdog
    SOURCES "${SRC_FOLDER}/watchdog.sv"
            "${FPGA_ELEMENTS_FOLDER}/CDC_Bit_Synchronizer.v")

# wb_sysregs bus slave (sequential): single-cycle ack + full read-decode
# correctness, uptime monotonicity, uptime_latch capture, and cam_reinit pulse.
register_formal(wb_sysregs wb_sysregs
    SOURCES "${SRC_FOLDER}/modbus/wb_sysregs.sv")

# wb_osd bus slave (sequential): decode + the clear-sweep invariants (bounded
# sweep address, blanks each cell, ends + homes the cursor) + cursor wrap +
# osd_enable control. The 1020-cell sweep is proven WITHOUT unrolling 1020 cycles.
register_formal(wb_osd wb_osd
    SOURCES "${SRC_FOLDER}/modbus/wb_osd.sv")

# wb_grab bus slave (sequential, multi-cycle stream FSM): Moore ack, single-cycle
# control pulses, defined state, deterministic FSM progress (the only stalls are
# the two grab_busy fetch-waits -> no internal deadlock), stream-pointer advance.
# (Full temporal liveness needs an aiger engine -- see SBY_LIVE and sby/README.md.)
register_formal(wb_grab wb_grab
    SOURCES "${SRC_FOLDER}/modbus/wb_grab.sv")
