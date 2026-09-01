# m0_m1_apply_bd_v13_axis_bridge_no_infer.tcl
# Clean diagnostic version after v11.
#
# v11 intentionally disconnected axi_dma_0/S_AXIS_S2MM interface and wired the
# scalar pins directly, which makes Vivado Validate Design report the interface
# as unconnected even when the individual pins are wired.  v13 keeps the same
# diagnostic idea but inserts a tiny RTL bridge:
#   pl_capture_logic_0 plain scalar data/keep/valid/ready/last
#       -> axis_manual_bridge_v13 scalar input
#       -> axis_manual_bridge_v13/M_AXIS interface
#       -> axi_dma_0/S_AXIS_S2MM interface
# This keeps Validate Design clean and still avoids relying on PL-side AXIS
# interface inference.

set bd_name ps_system
set bd_file [file normalize "DS_system.srcs/sources_1/bd/${bd_name}/${bd_name}.bd"]
set bridge_src [file normalize "DS_system.srcs/sources_1/imports/pl_reset_update/axis_manual_bridge_v13.v"]

proc m01_log {s} { puts "M0/M1 v13: $s" }

proc m01_set_prop_if_present {obj prop val} {
    if {![llength $obj]} { return }
    if {[lsearch -exact [list_property $obj] $prop] >= 0} {
        catch {set_property $prop $val $obj} msg
        if {$msg ne ""} { m01_log "set $prop on $obj note: $msg" }
    }
}

proc m01_force_freq_hz {obj hz} {
    if {![llength $obj]} { return }
    foreach prop [list CONFIG.FREQ_HZ FREQ_HZ] {
        m01_set_prop_if_present $obj $prop $hz
    }
}

proc m01_disconnect_intf_pin {pin_name} {
    set pin [get_bd_intf_pins -quiet $pin_name]
    if {![llength $pin]} { return }
    set nets [get_bd_intf_nets -quiet -of_objects $pin]
    foreach n $nets {
        catch {disconnect_bd_intf_net $n $pin} msg
        if {$msg ne ""} { m01_log "disconnect intf $pin_name from $n note: $msg" }
    }
}

proc m01_disconnect_pin {pin_name} {
    set pin [get_bd_pins -quiet $pin_name]
    if {![llength $pin]} { return }
    set nets [get_bd_nets -quiet -of_objects $pin]
    foreach n $nets {
        catch {disconnect_bd_net $n $pin} msg
        if {$msg ne ""} { m01_log "disconnect pin $pin_name from $n note: $msg" }
    }
}

proc m01_connect_pin_to_existing_net {net_obj pin_obj} {
    if {![llength $net_obj] || ![llength $pin_obj]} { return }
    set cur_net [get_bd_nets -quiet -of_objects $pin_obj]
    if {[llength $cur_net]} {
        if {[string equal [get_property NAME $cur_net] [get_property NAME $net_obj]]} { return }
        catch {disconnect_bd_net $cur_net $pin_obj} msg
        if {$msg ne ""} { m01_log "disconnect pin net note for $pin_obj: $msg" }
    }
    catch {connect_bd_net -net $net_obj $pin_obj} msg
    if {$msg ne ""} { m01_log "connect -net note for $pin_obj: $msg" }
}

proc m01_connect_pins_named {net_name src_name dst_name} {
    set src [get_bd_pins -quiet $src_name]
    set dst [get_bd_pins -quiet $dst_name]
    if {![llength $src]} { error "Missing BD pin: $src_name" }
    if {![llength $dst]} { error "Missing BD pin: $dst_name" }

    m01_disconnect_pin $src_name
    m01_disconnect_pin $dst_name
    set old [get_bd_nets -quiet $net_name]
    if {[llength $old]} { catch {delete_bd_objs $old} }
    create_bd_net $net_name
    connect_bd_net -net [get_bd_nets $net_name] $src $dst
    m01_log "wired $src_name -> $dst_name as $net_name"
}

proc m01_connect_intf {a b} {
    if {![llength $a] || ![llength $b]} { return }
    catch {connect_bd_intf_net $a $b} msg
    if {$msg ne ""} { m01_log "connect intf note: $msg" }
}

if {[catch {open_bd_design $bd_file} msg]} {
    m01_log "open_bd_design returned: $msg"
}
current_bd_design $bd_name

if {![file exists $bridge_src]} {
    error "Cannot find axis_manual_bridge_v13.v at: $bridge_src"
}
catch {add_files -norecurse $bridge_src} msg
if {$msg ne ""} { m01_log "add bridge source note: $msg" }
catch {update_compile_order -fileset sources_1}

if {[llength [get_bd_cells -quiet pl_capture_logic_0]]} {
    catch {update_module_reference pl_capture_logic_0} msg
    if {$msg ne ""} { m01_log "update_module_reference pl_capture_logic_0: $msg" }
} else {
    error "Cannot find pl_capture_logic_0."
}
if {![llength [get_bd_cells -quiet axi_dma_0]]} {
    error "Cannot find axi_dma_0. Run the M0/M1 base apply script first."
}

# Remove stale v9/v10/v11 FIFO/manual path objects and nets.
foreach p [list \
    pl_capture_logic_0/M_AXIS_FRAME \
    axis_frame_fifo_0/S_AXIS \
    axis_frame_fifo_0/M_AXIS \
    m1_axis_bridge_0/M_AXIS \
    axi_dma_0/S_AXIS_S2MM \
] {
    m01_disconnect_intf_pin $p
}
foreach p [list \
    axi_dma_0/s_axis_s2mm_tdata \
    axi_dma_0/s_axis_s2mm_tkeep \
    axi_dma_0/s_axis_s2mm_tvalid \
    axi_dma_0/s_axis_s2mm_tready \
    axi_dma_0/s_axis_s2mm_tlast \
    pl_capture_logic_0/M_AXIS_FRAME_TDATA \
    pl_capture_logic_0/M_AXIS_FRAME_TKEEP \
    pl_capture_logic_0/M_AXIS_FRAME_TVALID \
    pl_capture_logic_0/M_AXIS_FRAME_TREADY \
    pl_capture_logic_0/M_AXIS_FRAME_TLAST \
] {
    m01_disconnect_pin $p
}
foreach c [list axis_frame_fifo_0 m1_plrst_inv_0 m1_fifo_rst_and_0 m1_axis_bridge_0] {
    set cell [get_bd_cells -quiet $c]
    if {[llength $cell]} {
        m01_log "delete stale $c"
        catch {delete_bd_objs $cell} msg
        if {$msg ne ""} { m01_log "delete $c note: $msg" }
    }
}
foreach n [list m1_axis_tdata m1_axis_tkeep m1_axis_tvalid m1_axis_tready m1_axis_tlast \
                m1_pl_axis_tdata m1_pl_axis_tkeep m1_pl_axis_tvalid m1_pl_axis_tready m1_pl_axis_tlast] {
    set net [get_bd_nets -quiet $n]
    if {[llength $net]} { catch {delete_bd_objs $net} }
}

# Create the bridge module.
m01_log "create m1_axis_bridge_0 from axis_manual_bridge_v13"
create_bd_cell -type module -reference axis_manual_bridge_v13 m1_axis_bridge_0

# Clocks/resets.
set clk_net [get_bd_nets -quiet CLK_50M_0_1]
set rst_net [get_bd_nets -quiet RST_N_1]
if {![llength $clk_net]} { error "Cannot find clock net CLK_50M_0_1" }
if {![llength $rst_net]} { error "Cannot find reset net RST_N_1" }
foreach pin_name [list \
    axi_dma_0/s_axi_lite_aclk \
    axi_dma_0/m_axi_sg_aclk \
    axi_dma_0/m_axi_s2mm_aclk \
    axi_dma_0/s_axis_s2mm_aclk \
    hp_smartconnect_0/aclk \
    processing_system7_0/S_AXI_HP0_ACLK \
    m1_axis_bridge_0/aclk \
] {
    set pin [get_bd_pins -quiet $pin_name]
    if {[llength $pin]} { m01_connect_pin_to_existing_net $clk_net $pin }
}
foreach pin_name [list \
    axi_dma_0/axi_resetn \
    hp_smartconnect_0/aresetn \
    m1_axis_bridge_0/aresetn \
] {
    set pin [get_bd_pins -quiet $pin_name]
    if {[llength $pin]} { m01_connect_pin_to_existing_net $rst_net $pin }
}

# PL scalar pins -> bridge non-AXIS-inferred scalar pins. TLAST is explicit on this side.
m01_connect_pins_named m1_pl_axis_tdata  pl_capture_logic_0/M_AXIS_FRAME_TDATA  m1_axis_bridge_0/in_data
m01_connect_pins_named m1_pl_axis_tkeep  pl_capture_logic_0/M_AXIS_FRAME_TKEEP  m1_axis_bridge_0/in_keep
m01_connect_pins_named m1_pl_axis_tvalid pl_capture_logic_0/M_AXIS_FRAME_TVALID m1_axis_bridge_0/in_valid
m01_connect_pins_named m1_pl_axis_tready m1_axis_bridge_0/out_ready              pl_capture_logic_0/M_AXIS_FRAME_TREADY
m01_connect_pins_named m1_pl_axis_tlast  pl_capture_logic_0/M_AXIS_FRAME_TLAST  m1_axis_bridge_0/in_last

# Bridge output is a real AXIS interface, so DMA validate remains clean.
m01_connect_intf [get_bd_intf_pins -quiet m1_axis_bridge_0/M_AXIS] [get_bd_intf_pins -quiet axi_dma_0/S_AXIS_S2MM]

foreach obj_name [list \
    pl_capture_logic_0/CLK_50M \
    m1_axis_bridge_0/M_AXIS \
    axi_dma_0/S_AXIS_S2MM \
] {
    set pin  [get_bd_pins -quiet $obj_name]
    set intf [get_bd_intf_pins -quiet $obj_name]
    if {[llength $pin]}  { m01_force_freq_hz $pin 50000000 }
    if {[llength $intf]} { m01_force_freq_hz $intf 50000000 }
}

assign_bd_address
validate_bd_design
save_bd_design
m01_log "v13 bridge path applied. Upstream pins are deliberately renamed so Vivado will not infer an unclocked /s AXIS interface."
