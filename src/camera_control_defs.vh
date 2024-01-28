`ifndef __CAMERA_CONTROL_DEFS_VH__
`define __CAMERA_CONTROL_DEFS_VH__

`ifndef WRAP_SIM
`define WRAP_SIM(x) \
    `ifdef __ICARUS__ \
        x \
    `endif
`endif

package BufferControllerTypes;

typedef enum logic[2:0] {
    BUFFER_AVAILABLE,
    BUFFER_WRITE_BUSY,
    BUFFER_READ_BUSY,
    BUFFER_DISPLAYED,
    BUFFER_UPDATED
} BufferStates;

endpackage

`endif /* __CAMERA_CONTROL_DEFS_VH__ */
