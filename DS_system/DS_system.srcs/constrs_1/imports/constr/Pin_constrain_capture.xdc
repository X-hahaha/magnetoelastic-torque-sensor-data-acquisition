###############################################################################
# Pin_constrain_capture.xdc
# Based on the pin file you uploaded.
# This periodic-capture version has no external capture key port.
###############################################################################

# 50 MHz system clock and reset
set_property PACKAGE_PIN U18 [get_ports CLK_50M]
set_property IOSTANDARD LVCMOS18 [get_ports CLK_50M]
create_clock -period 20.000 -name CLK_50M [get_ports CLK_50M]

set_property PACKAGE_PIN N15 [get_ports RST_N]
set_property IOSTANDARD LVCMOS18 [get_ports RST_N]


# AD9268 parallel CMOS interface
set_property PACKAGE_PIN K17 [get_ports ADC_CLK]
set_property PACKAGE_PIN J18 [get_ports ADC_DCOA]
set_property PACKAGE_PIN H16 [get_ports ADC_DCOB]
set_property PACKAGE_PIN V12 [get_ports ADC_ORA]
set_property PACKAGE_PIN H17 [get_ports ADC_ORB]
set_property PACKAGE_PIN T12 [get_ports ADC_CSB]
set_property PACKAGE_PIN U14 [get_ports ADC_SCLK]
set_property PACKAGE_PIN W13 [get_ports ADC_SDIO]
set_property PACKAGE_PIN T10 [get_ports ADC_PDWN]
set_property PACKAGE_PIN T11 [get_ports ADC_OEB]

set_property PACKAGE_PIN G19 [get_ports {ADC_INA[0]}]
set_property PACKAGE_PIN G20 [get_ports {ADC_INA[1]}]
set_property PACKAGE_PIN G17 [get_ports {ADC_INA[2]}]
set_property PACKAGE_PIN G18 [get_ports {ADC_INA[3]}]
set_property PACKAGE_PIN F19 [get_ports {ADC_INA[4]}]
set_property PACKAGE_PIN F20 [get_ports {ADC_INA[5]}]
set_property PACKAGE_PIN F16 [get_ports {ADC_INA[6]}]
set_property PACKAGE_PIN F17 [get_ports {ADC_INA[7]}]
set_property PACKAGE_PIN E18 [get_ports {ADC_INA[8]}]
set_property PACKAGE_PIN E19 [get_ports {ADC_INA[9]}]
set_property PACKAGE_PIN E17 [get_ports {ADC_INA[10]}]
set_property PACKAGE_PIN D18 [get_ports {ADC_INA[11]}]
set_property PACKAGE_PIN D19 [get_ports {ADC_INA[12]}]
set_property PACKAGE_PIN D20 [get_ports {ADC_INA[13]}]
set_property PACKAGE_PIN C20 [get_ports {ADC_INA[14]}]
set_property PACKAGE_PIN B20 [get_ports {ADC_INA[15]}]

set_property PACKAGE_PIN L20 [get_ports {ADC_INB[0]}]
set_property PACKAGE_PIN L19 [get_ports {ADC_INB[1]}]
set_property PACKAGE_PIN M18 [get_ports {ADC_INB[2]}]
set_property PACKAGE_PIN M17 [get_ports {ADC_INB[3]}]
set_property PACKAGE_PIN J14 [get_ports {ADC_INB[4]}]
set_property PACKAGE_PIN K14 [get_ports {ADC_INB[5]}]
set_property PACKAGE_PIN J16 [get_ports {ADC_INB[6]}]
set_property PACKAGE_PIN K16 [get_ports {ADC_INB[7]}]
set_property PACKAGE_PIN K18 [get_ports {ADC_INB[8]}]
set_property PACKAGE_PIN K19 [get_ports {ADC_INB[9]}]
set_property PACKAGE_PIN J19 [get_ports {ADC_INB[10]}]
set_property PACKAGE_PIN J20 [get_ports {ADC_INB[11]}]
set_property PACKAGE_PIN H20 [get_ports {ADC_INB[12]}]
set_property PACKAGE_PIN H15 [get_ports {ADC_INB[13]}]
set_property PACKAGE_PIN H18 [get_ports {ADC_INB[14]}]
set_property PACKAGE_PIN G15 [get_ports {ADC_INB[15]}]

set_property IOSTANDARD LVCMOS18 [get_ports ADC_CLK]
set_property IOSTANDARD LVCMOS18 [get_ports ADC_DCOA]
set_property IOSTANDARD LVCMOS18 [get_ports ADC_DCOB]
set_property IOSTANDARD LVCMOS18 [get_ports ADC_ORA]
set_property IOSTANDARD LVCMOS18 [get_ports ADC_ORB]
set_property IOSTANDARD LVCMOS18 [get_ports ADC_CSB]
set_property IOSTANDARD LVCMOS18 [get_ports ADC_SCLK]
set_property IOSTANDARD LVCMOS18 [get_ports ADC_SDIO]
set_property IOSTANDARD LVCMOS18 [get_ports ADC_PDWN]
set_property IOSTANDARD LVCMOS18 [get_ports ADC_OEB]
set_property IOSTANDARD LVCMOS18 [get_ports {ADC_INA[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports {ADC_INB[*]}]

# 5 independent laser RS485 UART interfaces and 1 temperature RS485 UART interface
set_property PACKAGE_PIN V20 [get_ports TXD_LAYSER1]
set_property PACKAGE_PIN W20 [get_ports RXD_LAYSER1]
set_property PACKAGE_PIN W18 [get_ports TXD_LAYSER2]
set_property PACKAGE_PIN W19 [get_ports RXD_LAYSER2]
set_property PACKAGE_PIN Y18 [get_ports TXD_LAYSER3]
set_property PACKAGE_PIN Y19 [get_ports RXD_LAYSER3]
set_property PACKAGE_PIN V16 [get_ports TXD_LAYSER4]
set_property PACKAGE_PIN W16 [get_ports RXD_LAYSER4]
set_property PACKAGE_PIN V17 [get_ports TXD_LAYSER5]
set_property PACKAGE_PIN V18 [get_ports RXD_LAYSER5]
set_property PACKAGE_PIN U20 [get_ports TXD_TEMPERATURE]
set_property PACKAGE_PIN T20 [get_ports RXD_TEMPERATURE]

set_property IOSTANDARD LVCMOS18 [get_ports TXD_LAYSER1]
set_property IOSTANDARD LVCMOS18 [get_ports RXD_LAYSER1]
set_property IOSTANDARD LVCMOS18 [get_ports TXD_LAYSER2]
set_property IOSTANDARD LVCMOS18 [get_ports RXD_LAYSER2]
set_property IOSTANDARD LVCMOS18 [get_ports TXD_LAYSER3]
set_property IOSTANDARD LVCMOS18 [get_ports RXD_LAYSER3]
set_property IOSTANDARD LVCMOS18 [get_ports TXD_LAYSER4]
set_property IOSTANDARD LVCMOS18 [get_ports RXD_LAYSER4]
set_property IOSTANDARD LVCMOS18 [get_ports TXD_LAYSER5]
set_property IOSTANDARD LVCMOS18 [get_ports RXD_LAYSER5]
set_property IOSTANDARD LVCMOS18 [get_ports TXD_TEMPERATURE]
set_property IOSTANDARD LVCMOS18 [get_ports RXD_TEMPERATURE]

# Removed stale manual ILA hookup. The current block design has no u_ila_0
# debug core, so these commands caused critical warnings during implementation.
# connect_debug_port u_ila_0/clk ...
# connect_debug_port u_ila_0/probe0 ...
# connect_debug_port u_ila_0/probe1 ...
# connect_debug_port u_ila_0/probe2 ...
# connect_debug_port u_ila_0/probe3 ...
# connect_debug_port u_ila_0/probe4 ...
# connect_debug_port u_ila_0/probe5 ...
# connect_debug_port u_ila_0/probe6 ...
# connect_debug_port u_ila_0/probe7 ...
# connect_debug_port u_ila_0/probe8 ...
# connect_debug_port dbg_hub/clk ...






