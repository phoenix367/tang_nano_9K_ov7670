# Formal verification targets (yosys). Registered only when a yosys binary was
# found (see the top-level CMakeLists). Each proof reads the RTL with -DFORMAL so
# the `ifdef FORMAL properties compile in, then proves the assertions.
#
# wb_interconnect is purely combinational, so yosys's built-in SAT solver proves
# it EXHAUSTIVELY with no external SMT solver / sby needed. `sat -verify` exits
# non-zero on a failed proof, so it maps straight onto a ctest pass/fail.
#
# ctest labels: `formal` plus the proof name -> `ctest -L formal`.

# register_formal(<name> <top_module> <src.sv> [more.sv ...])
function(register_formal NAME TOP)
    set(YS_FILE "${CMAKE_CURRENT_BINARY_DIR}/${NAME}.ys")
    set(YS_SCRIPT "")
    foreach (SRC IN LISTS ARGN)
        string(APPEND YS_SCRIPT "read_verilog -sv -formal -DFORMAL ${SRC}\n")
    endforeach()
    string(APPEND YS_SCRIPT "prep -top ${TOP}\n")
    string(APPEND YS_SCRIPT "chformal -cover -remove\n")  # sat consumes asserts only
    string(APPEND YS_SCRIPT "sat -verify -prove-asserts\n")
    file(WRITE "${YS_FILE}" "${YS_SCRIPT}")

    add_test(NAME "formal_${NAME}" COMMAND "${YOSYS}" -s "${YS_FILE}")
    set_tests_properties("formal_${NAME}" PROPERTIES LABELS "formal;${NAME}")
endfunction()

# Pilot proof: Wishbone interconnect decode/mux (combinational, exhaustive).
register_formal(wb_interconnect wb_interconnect
    "${SRC_FOLDER}/modbus/wb_interconnect.sv")
