# m3_apply_bd.tcl
# Add the runtime waveform-length path (sample_count_cfg) between
# laser_axi_regs_0 and pl_capture_logic_0 for the dual-mode capture update.
# Prereq: updated laser_axi_regs.v / pl_capture_logic.v / fr16_adc_frame_axis.v
# are already in the project sources.
# Run from the DS_system project root in Vivado 2018.3 Tcl Console:
#   source m3_apply_bd.tcl

set bd_name ps_system
set bd_file [file normalize "DS_system.srcs/sources_1/bd/${bd_name}/${bd_name}.bd"]

proc m3_log {s} { puts "M3: $s" }

if {[catch {open_bd_design $bd_file} msg]} {
    m3_log "open_bd_design returned: $msg"
}
current_bd_design $bd_name

foreach cell {laser_axi_regs_0 pl_capture_logic_0} {
    if {![llength [get_bd_cells -quiet $cell]]} {
        error "Cannot find $cell"
    }
}

# Re-read the RTL so the new sample_count_cfg ports appear on both cells.
foreach cell {laser_axi_regs_0 pl_capture_logic_0} {
    catch {update_module_reference $cell} msg
    if {$msg ne ""} { m3_log "update_module_reference $cell note: $msg" }
}

set src_pin [get_bd_pins -quiet laser_axi_regs_0/sample_count_cfg]
set dst_pin [get_bd_pins -quiet pl_capture_logic_0/sample_count_cfg]
if {![llength $src_pin] || ![llength $dst_pin]} {
    error "sample_count_cfg pins missing after update_module_reference; check RTL sources"
}

if {[llength [get_bd_nets -quiet -of_objects $src_pin]]} {
    m3_log "sample_count_cfg already connected, skipping connect_bd_net"
} else {
    connect_bd_net $src_pin $dst_pin
    m3_log "connected laser_axi_regs_0/sample_count_cfg -> pl_capture_logic_0/sample_count_cfg"
}

# Keep the M1-validated DMA settings untouched.
set dma [get_bd_cells axi_dma_0]
set_property CONFIG.c_sg_include_stscntrl_strm 0 $dma
set_property CONFIG.c_sg_use_stsapp_length 0 $dma

validate_bd_design
save_bd_design
catch {update_compile_order -fileset sources_1}

m3_log "Runtime sample-count path connected."
m3_log "Next: Generate Output Products, bitstream, Export Hardware (Include Bitstream), then rebuild BSP/application."
