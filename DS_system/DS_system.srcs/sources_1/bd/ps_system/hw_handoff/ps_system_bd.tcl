
################################################################
# This is a generated script based on design: ps_system
#
# Though there are limitations about the generated script,
# the main purpose of this utility is to make learning
# IP Integrator Tcl commands easier.
################################################################

namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}
variable script_folder
set script_folder [_tcl::get_script_folder]

################################################################
# Check if script is running in correct Vivado version.
################################################################
set scripts_vivado_version 2018.3
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
   puts ""
   catch {common::send_msg_id "BD_TCL-109" "ERROR" "This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Please run the script in Vivado <$scripts_vivado_version> then open the design in Vivado <$current_vivado_version>. Upgrade the design by running \"Tools => Report => Report IP Status...\", then run write_bd_tcl to create an updated script."}

   return 1
}

################################################################
# START
################################################################

# To test this script, run the following commands from Vivado Tcl console:
# source ps_system_script.tcl


# The design that will be created by this Tcl script contains the following 
# module references:
# laser_axi_regs, axis_manual_bridge_v13, pl_capture_logic

# Please add the sources of those modules before sourcing this Tcl script.

# If there is no project opened, this script will create a
# project, but make sure you do not have an existing project
# <./myproj/project_1.xpr> in the current working folder.

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
   create_project project_1 myproj -part xc7z020clg400-2
}


# CHANGE DESIGN NAME HERE
variable design_name
set design_name ps_system

# If you do not already have an existing IP Integrator design open,
# you can create a design using the following command:
#    create_bd_design $design_name

# Creating design if needed
set errMsg ""
set nRet 0

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

if { ${design_name} eq "" } {
   # USE CASES:
   #    1) Design_name not set

   set errMsg "Please set the variable <design_name> to a non-empty value."
   set nRet 1

} elseif { ${cur_design} ne "" && ${list_cells} eq "" } {
   # USE CASES:
   #    2): Current design opened AND is empty AND names same.
   #    3): Current design opened AND is empty AND names diff; design_name NOT in project.
   #    4): Current design opened AND is empty AND names diff; design_name exists in project.

   if { $cur_design ne $design_name } {
      common::send_msg_id "BD_TCL-001" "INFO" "Changing value of <design_name> from <$design_name> to <$cur_design> since current design is empty."
      set design_name [get_property NAME $cur_design]
   }
   common::send_msg_id "BD_TCL-002" "INFO" "Constructing design in IPI design <$cur_design>..."

} elseif { ${cur_design} ne "" && $list_cells ne "" && $cur_design eq $design_name } {
   # USE CASES:
   #    5) Current design opened AND has components AND same names.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 1
} elseif { [get_files -quiet ${design_name}.bd] ne "" } {
   # USE CASES: 
   #    6) Current opened design, has components, but diff names, design_name exists in project.
   #    7) No opened design, design_name exists in project.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 2

} else {
   # USE CASES:
   #    8) No opened design, design_name not in project.
   #    9) Current opened design, has components, but diff names, design_name not in project.

   common::send_msg_id "BD_TCL-003" "INFO" "Currently there is no design <$design_name> in project, so creating one..."

   create_bd_design $design_name

   common::send_msg_id "BD_TCL-004" "INFO" "Making design <$design_name> as current_bd_design."
   current_bd_design $design_name

}

common::send_msg_id "BD_TCL-005" "INFO" "Currently the variable <design_name> is equal to \"$design_name\"."

if { $nRet != 0 } {
   catch {common::send_msg_id "BD_TCL-114" "ERROR" $errMsg}
   return $nRet
}

##################################################################
# DESIGN PROCs
##################################################################



# Procedure to create entire design; Provide argument to make
# procedure reusable. If parentCell is "", will use root.
proc create_root_design { parentCell } {

  variable script_folder
  variable design_name

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_msg_id "BD_TCL-100" "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_msg_id "BD_TCL-101" "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj


  # Create interface ports
  set DDR [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR ]
  set FIXED_IO [ create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO ]

  # Create ports
  set ADC_CLK [ create_bd_port -dir O -type clk ADC_CLK ]
  set ADC_CSB [ create_bd_port -dir O ADC_CSB ]
  set ADC_DCOA [ create_bd_port -dir I ADC_DCOA ]
  set ADC_DCOB [ create_bd_port -dir I ADC_DCOB ]
  set ADC_INA [ create_bd_port -dir I -from 15 -to 0 ADC_INA ]
  set ADC_INB [ create_bd_port -dir I -from 15 -to 0 ADC_INB ]
  set ADC_OEB [ create_bd_port -dir O ADC_OEB ]
  set ADC_ORA [ create_bd_port -dir I ADC_ORA ]
  set ADC_ORB [ create_bd_port -dir I ADC_ORB ]
  set ADC_PDWN [ create_bd_port -dir O ADC_PDWN ]
  set ADC_SCLK [ create_bd_port -dir O ADC_SCLK ]
  set ADC_SDIO [ create_bd_port -dir IO ADC_SDIO ]
  set CLK_50M [ create_bd_port -dir I -type clk CLK_50M ]
  set_property -dict [ list \
   CONFIG.ASSOCIATED_RESET {RST_N} \
   CONFIG.FREQ_HZ {50000000} \
 ] $CLK_50M
  set RST_N [ create_bd_port -dir I -type rst RST_N ]
  set_property -dict [ list \
   CONFIG.POLARITY {ACTIVE_LOW} \
 ] $RST_N
  set RXD_LAYSER1 [ create_bd_port -dir O RXD_LAYSER1 ]
  set RXD_LAYSER2 [ create_bd_port -dir O RXD_LAYSER2 ]
  set RXD_LAYSER3 [ create_bd_port -dir O RXD_LAYSER3 ]
  set RXD_LAYSER4 [ create_bd_port -dir O RXD_LAYSER4 ]
  set RXD_LAYSER5 [ create_bd_port -dir O RXD_LAYSER5 ]
  set RXD_TEMPERATURE [ create_bd_port -dir O RXD_TEMPERATURE ]
  set TXD_LAYSER1 [ create_bd_port -dir I TXD_LAYSER1 ]
  set TXD_LAYSER2 [ create_bd_port -dir I TXD_LAYSER2 ]
  set TXD_LAYSER3 [ create_bd_port -dir I TXD_LAYSER3 ]
  set TXD_LAYSER4 [ create_bd_port -dir I TXD_LAYSER4 ]
  set TXD_LAYSER5 [ create_bd_port -dir I TXD_LAYSER5 ]
  set TXD_TEMPERATURE [ create_bd_port -dir I TXD_TEMPERATURE ]

  # Create instance: axi_dma_0, and set properties
  set axi_dma_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0 ]
  set_property -dict [ list \
   CONFIG.c_enable_multi_channel {0} \
   CONFIG.c_include_mm2s {0} \
   CONFIG.c_include_s2mm {1} \
   CONFIG.c_include_s2mm_dre {0} \
   CONFIG.c_include_sg {1} \
   CONFIG.c_m_axi_s2mm_data_width {64} \
   CONFIG.c_sg_include_stscntrl_strm {0} \
   CONFIG.c_sg_length_width {23} \
   CONFIG.c_sg_use_stsapp_length {0} \
 ] $axi_dma_0

  # Create instance: hp_smartconnect_0, and set properties
  set hp_smartconnect_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 hp_smartconnect_0 ]
  set_property -dict [ list \
   CONFIG.NUM_MI {1} \
   CONFIG.NUM_SI {2} \
 ] $hp_smartconnect_0

  # Create instance: laser_axi_regs_0, and set properties
  set block_name laser_axi_regs
  set block_cell_name laser_axi_regs_0
  if { [catch {set laser_axi_regs_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_msg_id "BD_TCL-105" "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $laser_axi_regs_0 eq "" } {
     catch {common::send_msg_id "BD_TCL-106" "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: m1_axis_bridge_0, and set properties
  set block_name axis_manual_bridge_v13
  set block_cell_name m1_axis_bridge_0
  if { [catch {set m1_axis_bridge_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_msg_id "BD_TCL-105" "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $m1_axis_bridge_0 eq "" } {
     catch {common::send_msg_id "BD_TCL-106" "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: pl_capture_logic_0, and set properties
  set block_name pl_capture_logic
  set block_cell_name pl_capture_logic_0
  if { [catch {set pl_capture_logic_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_msg_id "BD_TCL-105" "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $pl_capture_logic_0 eq "" } {
     catch {common::send_msg_id "BD_TCL-106" "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: processing_system7_0, and set properties
  set processing_system7_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0 ]
  set_property -dict [ list \
   CONFIG.PCW_ACT_APU_PERIPHERAL_FREQMHZ {666.666687} \
   CONFIG.PCW_ACT_CAN_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_DCI_PERIPHERAL_FREQMHZ {10.158730} \
   CONFIG.PCW_ACT_ENET0_PERIPHERAL_FREQMHZ {125.000000} \
   CONFIG.PCW_ACT_ENET1_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ {50.000000} \
   CONFIG.PCW_ACT_FPGA1_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_FPGA2_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_FPGA3_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_PCAP_PERIPHERAL_FREQMHZ {200.000000} \
   CONFIG.PCW_ACT_QSPI_PERIPHERAL_FREQMHZ {200.000000} \
   CONFIG.PCW_ACT_SDIO_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_SMC_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_SPI_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_TPIU_PERIPHERAL_FREQMHZ {200.000000} \
   CONFIG.PCW_ACT_TTC0_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC0_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC0_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC1_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC1_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC1_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_UART_PERIPHERAL_FREQMHZ {100.000000} \
   CONFIG.PCW_ACT_WDT_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ARMPLL_CTRL_FBDIV {40} \
   CONFIG.PCW_CAN_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_CAN_PERIPHERAL_DIVISOR1 {1} \
   CONFIG.PCW_CLK0_FREQ {50000000} \
   CONFIG.PCW_CLK1_FREQ {10000000} \
   CONFIG.PCW_CLK2_FREQ {10000000} \
   CONFIG.PCW_CLK3_FREQ {10000000} \
   CONFIG.PCW_CPU_CPU_PLL_FREQMHZ {1333.333} \
   CONFIG.PCW_CPU_PERIPHERAL_DIVISOR0 {2} \
   CONFIG.PCW_DCI_PERIPHERAL_DIVISOR0 {15} \
   CONFIG.PCW_DCI_PERIPHERAL_DIVISOR1 {7} \
   CONFIG.PCW_DDRPLL_CTRL_FBDIV {32} \
   CONFIG.PCW_DDR_DDR_PLL_FREQMHZ {1066.667} \
   CONFIG.PCW_DDR_PERIPHERAL_DIVISOR0 {2} \
   CONFIG.PCW_DDR_RAM_HIGHADDR {0x3FFFFFFF} \
   CONFIG.PCW_ENET0_ENET0_IO {MIO 16 .. 27} \
   CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
   CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53} \
   CONFIG.PCW_ENET0_PERIPHERAL_CLKSRC {IO PLL} \
   CONFIG.PCW_ENET0_PERIPHERAL_DIVISOR0 {8} \
   CONFIG.PCW_ENET0_PERIPHERAL_DIVISOR1 {1} \
   CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ {1000 Mbps} \
   CONFIG.PCW_ENET0_RESET_ENABLE {0} \
   CONFIG.PCW_ENET1_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_ENET1_PERIPHERAL_DIVISOR1 {1} \
   CONFIG.PCW_ENET1_RESET_ENABLE {0} \
   CONFIG.PCW_ENET_RESET_ENABLE {0} \
   CONFIG.PCW_EN_EMIO_ENET0 {0} \
   CONFIG.PCW_EN_ENET0 {1} \
   CONFIG.PCW_EN_QSPI {1} \
   CONFIG.PCW_EN_UART1 {1} \
   CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR0 {5} \
   CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR1 {4} \
   CONFIG.PCW_FCLK1_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_FCLK1_PERIPHERAL_DIVISOR1 {1} \
   CONFIG.PCW_FCLK2_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_FCLK2_PERIPHERAL_DIVISOR1 {1} \
   CONFIG.PCW_FCLK3_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_FCLK3_PERIPHERAL_DIVISOR1 {1} \
   CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
   CONFIG.PCW_FPGA_FCLK1_ENABLE {0} \
   CONFIG.PCW_FPGA_FCLK2_ENABLE {0} \
   CONFIG.PCW_FPGA_FCLK3_ENABLE {0} \
   CONFIG.PCW_I2C_PERIPHERAL_FREQMHZ {25} \
   CONFIG.PCW_IOPLL_CTRL_FBDIV {30} \
   CONFIG.PCW_IO_IO_PLL_FREQMHZ {1000.000} \
   CONFIG.PCW_MIO_16_DIRECTION {out} \
   CONFIG.PCW_MIO_16_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_16_PULLUP {enabled} \
   CONFIG.PCW_MIO_16_SLEW {slow} \
   CONFIG.PCW_MIO_17_DIRECTION {out} \
   CONFIG.PCW_MIO_17_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_17_PULLUP {enabled} \
   CONFIG.PCW_MIO_17_SLEW {slow} \
   CONFIG.PCW_MIO_18_DIRECTION {out} \
   CONFIG.PCW_MIO_18_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_18_PULLUP {enabled} \
   CONFIG.PCW_MIO_18_SLEW {slow} \
   CONFIG.PCW_MIO_19_DIRECTION {out} \
   CONFIG.PCW_MIO_19_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_19_PULLUP {enabled} \
   CONFIG.PCW_MIO_19_SLEW {slow} \
   CONFIG.PCW_MIO_1_DIRECTION {out} \
   CONFIG.PCW_MIO_1_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_1_PULLUP {enabled} \
   CONFIG.PCW_MIO_1_SLEW {slow} \
   CONFIG.PCW_MIO_20_DIRECTION {out} \
   CONFIG.PCW_MIO_20_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_20_PULLUP {enabled} \
   CONFIG.PCW_MIO_20_SLEW {slow} \
   CONFIG.PCW_MIO_21_DIRECTION {out} \
   CONFIG.PCW_MIO_21_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_21_PULLUP {enabled} \
   CONFIG.PCW_MIO_21_SLEW {slow} \
   CONFIG.PCW_MIO_22_DIRECTION {in} \
   CONFIG.PCW_MIO_22_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_22_PULLUP {enabled} \
   CONFIG.PCW_MIO_22_SLEW {slow} \
   CONFIG.PCW_MIO_23_DIRECTION {in} \
   CONFIG.PCW_MIO_23_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_23_PULLUP {enabled} \
   CONFIG.PCW_MIO_23_SLEW {slow} \
   CONFIG.PCW_MIO_24_DIRECTION {in} \
   CONFIG.PCW_MIO_24_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_24_PULLUP {enabled} \
   CONFIG.PCW_MIO_24_SLEW {slow} \
   CONFIG.PCW_MIO_25_DIRECTION {in} \
   CONFIG.PCW_MIO_25_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_25_PULLUP {enabled} \
   CONFIG.PCW_MIO_25_SLEW {slow} \
   CONFIG.PCW_MIO_26_DIRECTION {in} \
   CONFIG.PCW_MIO_26_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_26_PULLUP {enabled} \
   CONFIG.PCW_MIO_26_SLEW {slow} \
   CONFIG.PCW_MIO_27_DIRECTION {in} \
   CONFIG.PCW_MIO_27_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_27_PULLUP {enabled} \
   CONFIG.PCW_MIO_27_SLEW {slow} \
   CONFIG.PCW_MIO_2_DIRECTION {inout} \
   CONFIG.PCW_MIO_2_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_2_PULLUP {disabled} \
   CONFIG.PCW_MIO_2_SLEW {slow} \
   CONFIG.PCW_MIO_3_DIRECTION {inout} \
   CONFIG.PCW_MIO_3_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_3_PULLUP {disabled} \
   CONFIG.PCW_MIO_3_SLEW {slow} \
   CONFIG.PCW_MIO_48_DIRECTION {out} \
   CONFIG.PCW_MIO_48_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_48_PULLUP {enabled} \
   CONFIG.PCW_MIO_48_SLEW {slow} \
   CONFIG.PCW_MIO_49_DIRECTION {in} \
   CONFIG.PCW_MIO_49_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_49_PULLUP {enabled} \
   CONFIG.PCW_MIO_49_SLEW {slow} \
   CONFIG.PCW_MIO_4_DIRECTION {inout} \
   CONFIG.PCW_MIO_4_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_4_PULLUP {disabled} \
   CONFIG.PCW_MIO_4_SLEW {slow} \
   CONFIG.PCW_MIO_52_DIRECTION {out} \
   CONFIG.PCW_MIO_52_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_52_PULLUP {enabled} \
   CONFIG.PCW_MIO_52_SLEW {slow} \
   CONFIG.PCW_MIO_53_DIRECTION {inout} \
   CONFIG.PCW_MIO_53_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_53_PULLUP {enabled} \
   CONFIG.PCW_MIO_53_SLEW {slow} \
   CONFIG.PCW_MIO_5_DIRECTION {inout} \
   CONFIG.PCW_MIO_5_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_5_PULLUP {disabled} \
   CONFIG.PCW_MIO_5_SLEW {slow} \
   CONFIG.PCW_MIO_6_DIRECTION {out} \
   CONFIG.PCW_MIO_6_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_6_PULLUP {disabled} \
   CONFIG.PCW_MIO_6_SLEW {slow} \
   CONFIG.PCW_MIO_TREE_PERIPHERALS {unassigned#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#Quad SPI Flash#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#Enet 0#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#UART 1#UART 1#unassigned#unassigned#Enet 0#Enet 0} \
   CONFIG.PCW_MIO_TREE_SIGNALS {unassigned#qspi0_ss_b#qspi0_io[0]#qspi0_io[1]#qspi0_io[2]#qspi0_io[3]/HOLD_B#qspi0_sclk#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#tx_clk#txd[0]#txd[1]#txd[2]#txd[3]#tx_ctl#rx_clk#rxd[0]#rxd[1]#rxd[2]#rxd[3]#rx_ctl#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#unassigned#tx#rx#unassigned#unassigned#mdc#mdio} \
   CONFIG.PCW_NAND_GRP_D8_ENABLE {0} \
   CONFIG.PCW_NAND_PERIPHERAL_ENABLE {0} \
   CONFIG.PCW_NOR_GRP_A25_ENABLE {0} \
   CONFIG.PCW_NOR_GRP_CS0_ENABLE {0} \
   CONFIG.PCW_NOR_GRP_CS1_ENABLE {0} \
   CONFIG.PCW_NOR_GRP_SRAM_CS0_ENABLE {0} \
   CONFIG.PCW_NOR_GRP_SRAM_CS1_ENABLE {0} \
   CONFIG.PCW_NOR_GRP_SRAM_INT_ENABLE {0} \
   CONFIG.PCW_NOR_PERIPHERAL_ENABLE {0} \
   CONFIG.PCW_PCAP_PERIPHERAL_DIVISOR0 {5} \
   CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
   CONFIG.PCW_QSPI_GRP_FBCLK_ENABLE {0} \
   CONFIG.PCW_QSPI_GRP_IO1_ENABLE {0} \
   CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE {1} \
   CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO {MIO 1 .. 6} \
   CONFIG.PCW_QSPI_GRP_SS1_ENABLE {0} \
   CONFIG.PCW_QSPI_PERIPHERAL_DIVISOR0 {5} \
   CONFIG.PCW_QSPI_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_QSPI_PERIPHERAL_FREQMHZ {200} \
   CONFIG.PCW_QSPI_QSPI_IO {MIO 1 .. 6} \
   CONFIG.PCW_SDIO_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_SINGLE_QSPI_DATA_MODE {x4} \
   CONFIG.PCW_SMC_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_SPI_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
   CONFIG.PCW_TPIU_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_UART1_GRP_FULL_ENABLE {0} \
   CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
   CONFIG.PCW_UART_PERIPHERAL_DIVISOR0 {10} \
   CONFIG.PCW_UART_PERIPHERAL_FREQMHZ {100} \
   CONFIG.PCW_UART_PERIPHERAL_VALID {1} \
   CONFIG.PCW_UIPARAM_ACT_DDR_FREQ_MHZ {533.333374} \
   CONFIG.PCW_UIPARAM_DDR_BANK_ADDR_COUNT {3} \
   CONFIG.PCW_UIPARAM_DDR_CL {7} \
   CONFIG.PCW_UIPARAM_DDR_COL_ADDR_COUNT {10} \
   CONFIG.PCW_UIPARAM_DDR_CWL {6} \
   CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {4096 MBits} \
   CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
   CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41J256M16 RE-125} \
   CONFIG.PCW_UIPARAM_DDR_ROW_ADDR_COUNT {15} \
   CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
   CONFIG.PCW_UIPARAM_DDR_T_FAW {40.0} \
   CONFIG.PCW_UIPARAM_DDR_T_RAS_MIN {35.0} \
   CONFIG.PCW_UIPARAM_DDR_T_RC {48.91} \
   CONFIG.PCW_UIPARAM_DDR_T_RCD {7} \
   CONFIG.PCW_UIPARAM_DDR_T_RP {7} \
   CONFIG.PCW_USE_S_AXI_HP0 {1} \
 ] $processing_system7_0

  # Create instance: smartconnect_0, and set properties
  set smartconnect_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0 ]
  set_property -dict [ list \
   CONFIG.NUM_MI {2} \
   CONFIG.NUM_SI {1} \
 ] $smartconnect_0

  # Create instance: system_ila_0, and set properties
  set system_ila_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 system_ila_0 ]
  set_property -dict [ list \
   CONFIG.C_BRAM_CNT {93.5} \
   CONFIG.C_DATA_DEPTH {8192} \
   CONFIG.C_NUM_MONITOR_SLOTS {2} \
   CONFIG.C_SLOT {0} \
   CONFIG.C_SLOT_1_INTF_TYPE {xilinx.com:interface:axis_rtl:1.0} \
 ] $system_ila_0

  # Create interface connections
  connect_bd_intf_net -intf_net axi_dma_0_M_AXI_S2MM [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins hp_smartconnect_0/S00_AXI]
  connect_bd_intf_net -intf_net axi_dma_0_M_AXI_SG [get_bd_intf_pins axi_dma_0/M_AXI_SG] [get_bd_intf_pins hp_smartconnect_0/S01_AXI]
connect_bd_intf_net -intf_net [get_bd_intf_nets axi_dma_0_M_AXI_SG] [get_bd_intf_pins axi_dma_0/M_AXI_SG] [get_bd_intf_pins system_ila_0/SLOT_0_AXI]
  connect_bd_intf_net -intf_net hp_smartconnect_0_M00_AXI [get_bd_intf_pins hp_smartconnect_0/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
  connect_bd_intf_net -intf_net m1_axis_bridge_0_M_AXIS1 [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM] [get_bd_intf_pins m1_axis_bridge_0/M_AXIS]
connect_bd_intf_net -intf_net [get_bd_intf_nets m1_axis_bridge_0_M_AXIS1] [get_bd_intf_pins m1_axis_bridge_0/M_AXIS] [get_bd_intf_pins system_ila_0/SLOT_1_AXIS]
  connect_bd_intf_net -intf_net processing_system7_0_DDR [get_bd_intf_ports DDR] [get_bd_intf_pins processing_system7_0/DDR]
  connect_bd_intf_net -intf_net processing_system7_0_FIXED_IO [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins processing_system7_0/FIXED_IO]
  connect_bd_intf_net -intf_net processing_system7_0_M_AXI_GP0 [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins smartconnect_0/S00_AXI]
  connect_bd_intf_net -intf_net smartconnect_0_M00_AXI [get_bd_intf_pins laser_axi_regs_0/S_AXI] [get_bd_intf_pins smartconnect_0/M00_AXI]
  connect_bd_intf_net -intf_net smartconnect_0_M01_AXI [get_bd_intf_pins axi_dma_0/S_AXI_LITE] [get_bd_intf_pins smartconnect_0/M01_AXI]

  # Create port connections
  connect_bd_net -net ADC_DCOA_0_1 [get_bd_ports ADC_DCOA] [get_bd_pins pl_capture_logic_0/ADC_DCOA]
  connect_bd_net -net ADC_DCOB_0_1 [get_bd_ports ADC_DCOB] [get_bd_pins pl_capture_logic_0/ADC_DCOB]
  connect_bd_net -net ADC_INA_0_1 [get_bd_ports ADC_INA] [get_bd_pins pl_capture_logic_0/ADC_INA]
  connect_bd_net -net ADC_INB_0_1 [get_bd_ports ADC_INB] [get_bd_pins pl_capture_logic_0/ADC_INB]
  connect_bd_net -net ADC_ORA_0_1 [get_bd_ports ADC_ORA] [get_bd_pins pl_capture_logic_0/ADC_ORA]
  connect_bd_net -net ADC_ORB_0_1 [get_bd_ports ADC_ORB] [get_bd_pins pl_capture_logic_0/ADC_ORB]
  connect_bd_net -net CLK_50M_0_1 [get_bd_ports CLK_50M] [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] [get_bd_pins axi_dma_0/m_axi_sg_aclk] [get_bd_pins axi_dma_0/s_axi_lite_aclk] [get_bd_pins hp_smartconnect_0/aclk] [get_bd_pins laser_axi_regs_0/S_AXI_ACLK] [get_bd_pins m1_axis_bridge_0/aclk] [get_bd_pins pl_capture_logic_0/CLK_50M] [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] [get_bd_pins smartconnect_0/aclk] [get_bd_pins system_ila_0/clk]
  connect_bd_net -net Net [get_bd_ports ADC_SDIO] [get_bd_pins pl_capture_logic_0/ADC_SDIO]
  connect_bd_net -net RST_N_1 [get_bd_ports RST_N] [get_bd_pins axi_dma_0/axi_resetn] [get_bd_pins hp_smartconnect_0/aresetn] [get_bd_pins laser_axi_regs_0/S_AXI_ARESETN] [get_bd_pins m1_axis_bridge_0/aresetn] [get_bd_pins pl_capture_logic_0/RST_N] [get_bd_pins smartconnect_0/aresetn]
  connect_bd_net -net TXD_LAYSER1_0_1 [get_bd_ports TXD_LAYSER1] [get_bd_pins pl_capture_logic_0/TXD_LAYSER1]
  connect_bd_net -net TXD_LAYSER2_0_1 [get_bd_ports TXD_LAYSER2] [get_bd_pins pl_capture_logic_0/TXD_LAYSER2]
  connect_bd_net -net TXD_LAYSER3_0_1 [get_bd_ports TXD_LAYSER3] [get_bd_pins pl_capture_logic_0/TXD_LAYSER3]
  connect_bd_net -net TXD_LAYSER4_0_1 [get_bd_ports TXD_LAYSER4] [get_bd_pins pl_capture_logic_0/TXD_LAYSER4]
  connect_bd_net -net TXD_LAYSER5_0_1 [get_bd_ports TXD_LAYSER5] [get_bd_pins pl_capture_logic_0/TXD_LAYSER5]
  connect_bd_net -net TXD_TEMPERATURE_0_1 [get_bd_ports TXD_TEMPERATURE] [get_bd_pins pl_capture_logic_0/TXD_TEMPERATURE]
  connect_bd_net -net laser_axi_regs_0_adc_sample_rd_addr [get_bd_pins laser_axi_regs_0/adc_sample_rd_addr] [get_bd_pins pl_capture_logic_0/ps_adc_sample_rd_addr]
  connect_bd_net -net laser_axi_regs_0_adc_sample_rd_en [get_bd_pins laser_axi_regs_0/adc_sample_rd_en] [get_bd_pins pl_capture_logic_0/ps_adc_sample_rd_en]
  connect_bd_net -net laser_axi_regs_0_pl_soft_reset_hold [get_bd_pins laser_axi_regs_0/pl_soft_reset_hold] [get_bd_pins pl_capture_logic_0/ps_pl_reset_hold]
  connect_bd_net -net m1_pl_axis_tdata [get_bd_pins m1_axis_bridge_0/in_data] [get_bd_pins pl_capture_logic_0/M_AXIS_FRAME_TDATA]
  connect_bd_net -net m1_pl_axis_tkeep [get_bd_pins m1_axis_bridge_0/in_keep] [get_bd_pins pl_capture_logic_0/M_AXIS_FRAME_TKEEP]
  connect_bd_net -net m1_pl_axis_tlast [get_bd_pins m1_axis_bridge_0/in_last] [get_bd_pins pl_capture_logic_0/M_AXIS_FRAME_TLAST]
  connect_bd_net -net m1_pl_axis_tready [get_bd_pins m1_axis_bridge_0/out_ready] [get_bd_pins pl_capture_logic_0/M_AXIS_FRAME_TREADY]
  connect_bd_net -net m1_pl_axis_tvalid [get_bd_pins m1_axis_bridge_0/in_valid] [get_bd_pins pl_capture_logic_0/M_AXIS_FRAME_TVALID]
  connect_bd_net -net pl_capture_logic_0_ADC_CLK [get_bd_ports ADC_CLK] [get_bd_pins pl_capture_logic_0/ADC_CLK]
  connect_bd_net -net pl_capture_logic_0_ADC_CSB [get_bd_ports ADC_CSB] [get_bd_pins pl_capture_logic_0/ADC_CSB]
  connect_bd_net -net pl_capture_logic_0_ADC_OEB [get_bd_ports ADC_OEB] [get_bd_pins pl_capture_logic_0/ADC_OEB]
  connect_bd_net -net pl_capture_logic_0_ADC_PDWN [get_bd_ports ADC_PDWN] [get_bd_pins pl_capture_logic_0/ADC_PDWN]
  connect_bd_net -net pl_capture_logic_0_ADC_SCLK [get_bd_ports ADC_SCLK] [get_bd_pins pl_capture_logic_0/ADC_SCLK]
  connect_bd_net -net pl_capture_logic_0_RXD_LAYSER1 [get_bd_ports RXD_LAYSER1] [get_bd_pins pl_capture_logic_0/RXD_LAYSER1]
  connect_bd_net -net pl_capture_logic_0_RXD_LAYSER2 [get_bd_ports RXD_LAYSER2] [get_bd_pins pl_capture_logic_0/RXD_LAYSER2]
  connect_bd_net -net pl_capture_logic_0_RXD_LAYSER3 [get_bd_ports RXD_LAYSER3] [get_bd_pins pl_capture_logic_0/RXD_LAYSER3]
  connect_bd_net -net pl_capture_logic_0_RXD_LAYSER4 [get_bd_ports RXD_LAYSER4] [get_bd_pins pl_capture_logic_0/RXD_LAYSER4]
  connect_bd_net -net pl_capture_logic_0_RXD_LAYSER5 [get_bd_ports RXD_LAYSER5] [get_bd_pins pl_capture_logic_0/RXD_LAYSER5]
  connect_bd_net -net pl_capture_logic_0_RXD_TEMPERATURE [get_bd_ports RXD_TEMPERATURE] [get_bd_pins pl_capture_logic_0/RXD_TEMPERATURE]
  connect_bd_net -net pl_capture_logic_0_ps_adc_a_filt_pp [get_bd_pins laser_axi_regs_0/adc_a_filt_pp] [get_bd_pins pl_capture_logic_0/ps_adc_a_filt_pp]
  connect_bd_net -net pl_capture_logic_0_ps_adc_a_raw_pp [get_bd_pins laser_axi_regs_0/adc_a_raw_pp] [get_bd_pins pl_capture_logic_0/ps_adc_a_raw_pp]
  connect_bd_net -net pl_capture_logic_0_ps_adc_b_filt_pp [get_bd_pins laser_axi_regs_0/adc_b_filt_pp] [get_bd_pins pl_capture_logic_0/ps_adc_b_filt_pp]
  connect_bd_net -net pl_capture_logic_0_ps_adc_b_raw_pp [get_bd_pins laser_axi_regs_0/adc_b_raw_pp] [get_bd_pins pl_capture_logic_0/ps_adc_b_raw_pp]
  connect_bd_net -net pl_capture_logic_0_ps_adc_sample_rd_data [get_bd_pins laser_axi_regs_0/adc_sample_rd_data] [get_bd_pins pl_capture_logic_0/ps_adc_sample_rd_data]
  connect_bd_net -net pl_capture_logic_0_ps_frame_id [get_bd_pins laser_axi_regs_0/frame_id] [get_bd_pins pl_capture_logic_0/ps_frame_id]
  connect_bd_net -net pl_capture_logic_0_ps_laser1_um [get_bd_pins laser_axi_regs_0/laser1_um] [get_bd_pins pl_capture_logic_0/ps_laser1_um]
  connect_bd_net -net pl_capture_logic_0_ps_laser2_um [get_bd_pins laser_axi_regs_0/laser2_um] [get_bd_pins pl_capture_logic_0/ps_laser2_um]
  connect_bd_net -net pl_capture_logic_0_ps_laser3_um [get_bd_pins laser_axi_regs_0/laser3_um] [get_bd_pins pl_capture_logic_0/ps_laser3_um]
  connect_bd_net -net pl_capture_logic_0_ps_laser4_um [get_bd_pins laser_axi_regs_0/laser4_um] [get_bd_pins pl_capture_logic_0/ps_laser4_um]
  connect_bd_net -net pl_capture_logic_0_ps_laser5_um [get_bd_pins laser_axi_regs_0/laser5_um] [get_bd_pins pl_capture_logic_0/ps_laser5_um]
  connect_bd_net -net pl_capture_logic_0_ps_sensor_crc_error [get_bd_pins laser_axi_regs_0/sensor_crc_error] [get_bd_pins pl_capture_logic_0/ps_sensor_crc_error]
  connect_bd_net -net pl_capture_logic_0_ps_sensor_frame_error [get_bd_pins laser_axi_regs_0/sensor_frame_error] [get_bd_pins pl_capture_logic_0/ps_sensor_frame_error]
  connect_bd_net -net pl_capture_logic_0_ps_sensor_timeout_error [get_bd_pins laser_axi_regs_0/sensor_timeout_error] [get_bd_pins pl_capture_logic_0/ps_sensor_timeout_error]
  connect_bd_net -net pl_capture_logic_0_ps_sensor_valid_seen [get_bd_pins laser_axi_regs_0/sensor_valid_seen] [get_bd_pins pl_capture_logic_0/ps_sensor_valid_seen]
  connect_bd_net -net pl_capture_logic_0_ps_temperature_x10 [get_bd_pins laser_axi_regs_0/temperature_x10] [get_bd_pins pl_capture_logic_0/ps_temperature_x10]

  # Create address segments
  create_bd_addr_seg -range 0x40000000 -offset 0x00000000 [get_bd_addr_spaces axi_dma_0/Data_SG] [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] SEG_processing_system7_0_HP0_DDR_LOWOCM
  create_bd_addr_seg -range 0x40000000 -offset 0x00000000 [get_bd_addr_spaces axi_dma_0/Data_S2MM] [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] SEG_processing_system7_0_HP0_DDR_LOWOCM
  create_bd_addr_seg -range 0x00010000 -offset 0x40400000 [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs axi_dma_0/S_AXI_LITE/Reg] SEG_axi_dma_0_Reg
  create_bd_addr_seg -range 0x00010000 -offset 0x43C00000 [get_bd_addr_spaces processing_system7_0/Data] [get_bd_addr_segs laser_axi_regs_0/S_AXI/reg0] SEG_laser_axi_regs_0_reg0


  # Restore current instance
  current_bd_instance $oldCurInst

  validate_bd_design
  save_bd_design
}
# End of create_root_design()


##################################################################
# MAIN FLOW
##################################################################

create_root_design ""


