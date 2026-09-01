# m2_apply_bd.tcl
# Refresh the real-ADC M2 RTL while preserving the M1-validated DMA/HP0 path.
# Run from the DS_system project root in Vivado 2018.3 Tcl Console:
#   source m2_apply_bd.tcl

set bd_name ps_system
set bd_file [file normalize "DS_system.srcs/sources_1/bd/${bd_name}/${bd_name}.bd"]
set m2_src  [file normalize "DS_system.srcs/sources_1/imports/fr16_m2/fr16_adc_frame_axis.v"]
set m2_tb   [file normalize "DS_system.srcs/sim_1/m2/tb_fr16_adc_frame_axis.sv"]

proc m2_log {s} { puts "M2: $s" }

if {![file exists $m2_src]} {
    error "Missing M2 source: $m2_src"
}

catch {add_files -norecurse $m2_src} msg
if {$msg ne ""} { m2_log "add_files note: $msg" }
catch {update_compile_order -fileset sources_1}
if {[file exists $m2_tb]} {
    catch {add_files -fileset sim_1 -norecurse $m2_tb} msg
    if {$msg ne ""} { m2_log "add testbench note: $msg" }
    catch {set_property file_type SystemVerilog [get_files $m2_tb]}
}

if {[catch {open_bd_design $bd_file} msg]} {
    m2_log "open_bd_design returned: $msg"
}
current_bd_design $bd_name

if {![llength [get_bd_cells -quiet pl_capture_logic_0]]} {
    error "Cannot find pl_capture_logic_0"
}
if {![llength [get_bd_cells -quiet axi_dma_0]]} {
    error "Cannot find axi_dma_0; restore the validated M0/M1 BD baseline first"
}

# Refresh the module reference after replacing the internal M1 synthetic source
# with the M2 real-ADC frame packer. External BD ports are intentionally unchanged.
catch {update_module_reference pl_capture_logic_0} msg
if {$msg ne ""} { m2_log "update_module_reference note: $msg" }

# Critical M1 fix: the design has no SG status/control AXIS stream. These values
# must remain disabled or completed BD status may never be written back.
set dma [get_bd_cells axi_dma_0]
set_property CONFIG.c_sg_include_stscntrl_strm 0 $dma
set_property CONFIG.c_sg_use_stsapp_length 0 $dma

validate_bd_design
save_bd_design
catch {update_compile_order -fileset sources_1}

m2_log "RTL refreshed; SG status/control stream remains disabled."
m2_log "Next: Generate Output Products, bitstream, Export Hardware (Include Bitstream), then rebuild BSP/application."
