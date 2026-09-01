`timescale 1ns / 1ps
/*
 * axis_manual_bridge_v13
 *
 * Diagnostic bridge for M0/M1.
 *
 * Why v13 exists:
 *   v12 used upstream pin names such as s_tdata/s_tvalid/s_tlast. Vivado may
 *   automatically infer those pins as an AXI4-Stream slave interface named "s".
 *   Because that inferred input interface is not meant to be a real BD interface,
 *   Validate Design can issue:
 *       AXI interface pin /m1_axis_bridge_0/s is not associated to any clock pin
 *
 * v13 avoids that by giving the upstream pins non-AXIS names and explicitly
 * marking them as ignored for interface inference.  The downstream side remains
 * a normal AXI4-Stream master interface connected to axi_dma_0/S_AXIS_S2MM.
 */
module axis_manual_bridge_v13 (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET aresetn, FREQ_HZ 50000000" *)
    input  wire        aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        aresetn,

    (* X_INTERFACE_IGNORE = "TRUE" *) input  wire [31:0] in_data,
    (* X_INTERFACE_IGNORE = "TRUE" *) input  wire [3:0]  in_keep,
    (* X_INTERFACE_IGNORE = "TRUE" *) input  wire        in_valid,
    (* X_INTERFACE_IGNORE = "TRUE" *) output wire        out_ready,
    (* X_INTERFACE_IGNORE = "TRUE" *) input  wire        in_last,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS, TDATA_NUM_BYTES 4, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1, FREQ_HZ 50000000" *)
    output wire [31:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *)
    output wire [3:0]  m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire        m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire        m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output wire        m_axis_tlast
);

    assign m_axis_tdata  = in_data;
    assign m_axis_tkeep  = in_keep;
    assign m_axis_tvalid = in_valid;
    assign out_ready     = m_axis_tready;
    assign m_axis_tlast  = in_last;

endmodule
