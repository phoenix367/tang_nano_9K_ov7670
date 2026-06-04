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
#
# Generates a yosys script that proves the module's `assert`s with the built-in
# SAT solver via temporal (k-)induction -- no external SMT solver needed. The
# flow is sequential-capable (works for combinational modules too):
#   flatten            : sat needs a single module
#   async2sync         : convert $adff (async reset) so sat can import the FFs
#   set-init-zero      : model power-up (FFs start 0, matching reset)
#   tempinduct         : unbounded proof by k-induction
#   -verify            : non-zero exit on a failed proof  -> ctest pass/fail
function(register_formal NAME TOP)
    set(YS_FILE "${CMAKE_CURRENT_BINARY_DIR}/${NAME}.ys")
    set(YS_SCRIPT "")
    foreach (SRC IN LISTS ARGN)
        string(APPEND YS_SCRIPT "read_verilog -sv -formal -DFORMAL -I ${SRC_FOLDER} ${SRC}\n")
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
    "${SRC_FOLDER}/modbus/wb_interconnect.sv")

# Round-robin arbiter (sequential): mutual exclusion + grant/req/enable/select
# invariants, proven by k-induction on a width-4 instance. The harness wrapper
# lives in sby/ so the third-party src/arbiter.v stays pristine.
register_formal(arbiter arbiter_formal
    "${SRC_FOLDER}/arbiter.v"
    "${CMAKE_CURRENT_SOURCE_DIR}/arbiter_formal.sv")
