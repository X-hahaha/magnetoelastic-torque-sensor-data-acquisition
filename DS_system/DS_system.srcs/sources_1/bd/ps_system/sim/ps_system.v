//Copyright 1986-2018 Xilinx, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2018.3 (win64) Build 2405991 Thu Dec  6 23:38:27 MST 2018
//Date        : Sat Aug  8 10:26:58 2026
//Host        : Yy running 64-bit major release  (build 9200)
//Command     : generate_target ps_system.bd
//Design      : ps_system
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

(* CORE_GENERATION_INFO = "ps_system,IP_Integrator,{x_ipVendor=xilinx.com,x_ipLibrary=BlockDiagram,x_ipName=ps_system,x_ipVersion=1.00.a,x_ipLanguage=VERILOG,numBlks=8,numReposBlks=8,numNonXlnxBlks=0,numHierBlks=0,maxHierDepth=0,numSysgenBlks=0,numHlsBlks=0,numHdlrefBlks=3,numPkgbdBlks=0,bdsource=USER,da_ps7_cnt=1,synth_mode=OOC_per_IP}" *) (* HW_HANDOFF = "ps_system.hwdef" *) 
module ps_system
   (ADC_CLK,
    ADC_CSB,
    ADC_DCOA,
    ADC_DCOB,
    ADC_INA,
    ADC_INB,
    ADC_OEB,
    ADC_ORA,
    ADC_ORB,
    ADC_PDWN,
    ADC_SCLK,
    ADC_SDIO,
    CLK_50M,
    DDR_addr,
    DDR_ba,
    DDR_cas_n,
    DDR_ck_n,
    DDR_ck_p,
    DDR_cke,
    DDR_cs_n,
    DDR_dm,
    DDR_dq,
    DDR_dqs_n,
    DDR_dqs_p,
    DDR_odt,
    DDR_ras_n,
    DDR_reset_n,
    DDR_we_n,
    FIXED_IO_ddr_vrn,
    FIXED_IO_ddr_vrp,
    FIXED_IO_mio,
    FIXED_IO_ps_clk,
    FIXED_IO_ps_porb,
    FIXED_IO_ps_srstb,
    RST_N,
    RXD_LAYSER1,
    RXD_LAYSER2,
    RXD_LAYSER3,
    RXD_LAYSER4,
    RXD_LAYSER5,
    RXD_TEMPERATURE,
    TXD_LAYSER1,
    TXD_LAYSER2,
    TXD_LAYSER3,
    TXD_LAYSER4,
    TXD_LAYSER5,
    TXD_TEMPERATURE);
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.ADC_CLK CLK" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.ADC_CLK, CLK_DOMAIN ps_system_pl_capture_logic_0_0_ADC_CLK, FREQ_HZ 100000000, INSERT_VIP 0, PHASE 0.000" *) output ADC_CLK;
  output ADC_CSB;
  input ADC_DCOA;
  input ADC_DCOB;
  input [15:0]ADC_INA;
  input [15:0]ADC_INB;
  output ADC_OEB;
  input ADC_ORA;
  input ADC_ORB;
  output ADC_PDWN;
  output ADC_SCLK;
  inout ADC_SDIO;
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK.CLK_50M CLK" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.CLK_50M, ASSOCIATED_RESET RST_N, CLK_DOMAIN ps_system_CLK_50M, FREQ_HZ 50000000, INSERT_VIP 0, PHASE 0.000" *) input CLK_50M;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR ADDR" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME DDR, AXI_ARBITRATION_SCHEME TDM, BURST_LENGTH 8, CAN_DEBUG false, CAS_LATENCY 11, CAS_WRITE_LATENCY 11, CS_ENABLED true, DATA_MASK_ENABLED true, DATA_WIDTH 8, MEMORY_TYPE COMPONENTS, MEM_ADDR_MAP ROW_COLUMN_BANK, SLOT Single, TIMEPERIOD_PS 1250" *) inout [14:0]DDR_addr;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR BA" *) inout [2:0]DDR_ba;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CAS_N" *) inout DDR_cas_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CK_N" *) inout DDR_ck_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CK_P" *) inout DDR_ck_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CKE" *) inout DDR_cke;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR CS_N" *) inout DDR_cs_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR DM" *) inout [3:0]DDR_dm;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR DQ" *) inout [31:0]DDR_dq;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR DQS_N" *) inout [3:0]DDR_dqs_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR DQS_P" *) inout [3:0]DDR_dqs_p;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR ODT" *) inout DDR_odt;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR RAS_N" *) inout DDR_ras_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR RESET_N" *) inout DDR_reset_n;
  (* X_INTERFACE_INFO = "xilinx.com:interface:ddrx:1.0 DDR WE_N" *) inout DDR_we_n;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO DDR_VRN" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME FIXED_IO, CAN_DEBUG false" *) inout FIXED_IO_ddr_vrn;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO DDR_VRP" *) inout FIXED_IO_ddr_vrp;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO MIO" *) inout [53:0]FIXED_IO_mio;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO PS_CLK" *) inout FIXED_IO_ps_clk;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO PS_PORB" *) inout FIXED_IO_ps_porb;
  (* X_INTERFACE_INFO = "xilinx.com:display_processing_system7:fixedio:1.0 FIXED_IO PS_SRSTB" *) inout FIXED_IO_ps_srstb;
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST.RST_N RST" *) (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.RST_N, INSERT_VIP 0, POLARITY ACTIVE_LOW" *) input RST_N;
  output RXD_LAYSER1;
  output RXD_LAYSER2;
  output RXD_LAYSER3;
  output RXD_LAYSER4;
  output RXD_LAYSER5;
  output RXD_TEMPERATURE;
  input TXD_LAYSER1;
  input TXD_LAYSER2;
  input TXD_LAYSER3;
  input TXD_LAYSER4;
  input TXD_LAYSER5;
  input TXD_TEMPERATURE;

  wire ADC_DCOA_0_1;
  wire ADC_DCOB_0_1;
  wire [15:0]ADC_INA_0_1;
  wire [15:0]ADC_INB_0_1;
  wire ADC_ORA_0_1;
  wire ADC_ORB_0_1;
  wire CLK_50M_0_1;
  wire Net;
  wire RST_N_1;
  wire TXD_LAYSER1_0_1;
  wire TXD_LAYSER2_0_1;
  wire TXD_LAYSER3_0_1;
  wire TXD_LAYSER4_0_1;
  wire TXD_LAYSER5_0_1;
  wire TXD_TEMPERATURE_0_1;
  wire [31:0]axi_dma_0_M_AXI_S2MM_AWADDR;
  wire [1:0]axi_dma_0_M_AXI_S2MM_AWBURST;
  wire [3:0]axi_dma_0_M_AXI_S2MM_AWCACHE;
  wire [7:0]axi_dma_0_M_AXI_S2MM_AWLEN;
  wire [2:0]axi_dma_0_M_AXI_S2MM_AWPROT;
  wire axi_dma_0_M_AXI_S2MM_AWREADY;
  wire [2:0]axi_dma_0_M_AXI_S2MM_AWSIZE;
  wire axi_dma_0_M_AXI_S2MM_AWVALID;
  wire axi_dma_0_M_AXI_S2MM_BREADY;
  wire [1:0]axi_dma_0_M_AXI_S2MM_BRESP;
  wire axi_dma_0_M_AXI_S2MM_BVALID;
  wire [63:0]axi_dma_0_M_AXI_S2MM_WDATA;
  wire axi_dma_0_M_AXI_S2MM_WLAST;
  wire axi_dma_0_M_AXI_S2MM_WREADY;
  wire [7:0]axi_dma_0_M_AXI_S2MM_WSTRB;
  wire axi_dma_0_M_AXI_S2MM_WVALID;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 ARADDR" *) (* DONT_TOUCH *) wire [31:0]axi_dma_0_M_AXI_SG_ARADDR;
  wire [1:0]axi_dma_0_M_AXI_SG_ARBURST;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 ARCACHE" *) (* DONT_TOUCH *) wire [3:0]axi_dma_0_M_AXI_SG_ARCACHE;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 ARLEN" *) (* DONT_TOUCH *) wire [7:0]axi_dma_0_M_AXI_SG_ARLEN;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 ARPROT" *) (* DONT_TOUCH *) wire [2:0]axi_dma_0_M_AXI_SG_ARPROT;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 ARREADY" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_ARREADY;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 ARSIZE" *) (* DONT_TOUCH *) wire [2:0]axi_dma_0_M_AXI_SG_ARSIZE;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 ARVALID" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_ARVALID;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 AWADDR" *) (* DONT_TOUCH *) wire [31:0]axi_dma_0_M_AXI_SG_AWADDR;
  wire [1:0]axi_dma_0_M_AXI_SG_AWBURST;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 AWCACHE" *) (* DONT_TOUCH *) wire [3:0]axi_dma_0_M_AXI_SG_AWCACHE;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 AWLEN" *) (* DONT_TOUCH *) wire [7:0]axi_dma_0_M_AXI_SG_AWLEN;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 AWPROT" *) (* DONT_TOUCH *) wire [2:0]axi_dma_0_M_AXI_SG_AWPROT;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 AWREADY" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_AWREADY;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 AWSIZE" *) (* DONT_TOUCH *) wire [2:0]axi_dma_0_M_AXI_SG_AWSIZE;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 AWVALID" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_AWVALID;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 BREADY" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_BREADY;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 BRESP" *) (* DONT_TOUCH *) wire [1:0]axi_dma_0_M_AXI_SG_BRESP;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 BVALID" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_BVALID;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 RDATA" *) (* DONT_TOUCH *) wire [31:0]axi_dma_0_M_AXI_SG_RDATA;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 RLAST" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_RLAST;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 RREADY" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_RREADY;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 RRESP" *) (* DONT_TOUCH *) wire [1:0]axi_dma_0_M_AXI_SG_RRESP;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 RVALID" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_RVALID;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 WDATA" *) (* DONT_TOUCH *) wire [31:0]axi_dma_0_M_AXI_SG_WDATA;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 WLAST" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_WLAST;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 WREADY" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_WREADY;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 WSTRB" *) (* DONT_TOUCH *) wire [3:0]axi_dma_0_M_AXI_SG_WSTRB;
  (* CONN_BUS_INFO = "axi_dma_0_M_AXI_SG xilinx.com:interface:aximm:1.0 AXI4 WVALID" *) (* DONT_TOUCH *) wire axi_dma_0_M_AXI_SG_WVALID;
  wire [31:0]hp_smartconnect_0_M00_AXI_ARADDR;
  wire [1:0]hp_smartconnect_0_M00_AXI_ARBURST;
  wire [3:0]hp_smartconnect_0_M00_AXI_ARCACHE;
  wire [3:0]hp_smartconnect_0_M00_AXI_ARLEN;
  wire [1:0]hp_smartconnect_0_M00_AXI_ARLOCK;
  wire [2:0]hp_smartconnect_0_M00_AXI_ARPROT;
  wire [3:0]hp_smartconnect_0_M00_AXI_ARQOS;
  wire hp_smartconnect_0_M00_AXI_ARREADY;
  wire [2:0]hp_smartconnect_0_M00_AXI_ARSIZE;
  wire hp_smartconnect_0_M00_AXI_ARVALID;
  wire [31:0]hp_smartconnect_0_M00_AXI_AWADDR;
  wire [1:0]hp_smartconnect_0_M00_AXI_AWBURST;
  wire [3:0]hp_smartconnect_0_M00_AXI_AWCACHE;
  wire [3:0]hp_smartconnect_0_M00_AXI_AWLEN;
  wire [1:0]hp_smartconnect_0_M00_AXI_AWLOCK;
  wire [2:0]hp_smartconnect_0_M00_AXI_AWPROT;
  wire [3:0]hp_smartconnect_0_M00_AXI_AWQOS;
  wire hp_smartconnect_0_M00_AXI_AWREADY;
  wire [2:0]hp_smartconnect_0_M00_AXI_AWSIZE;
  wire hp_smartconnect_0_M00_AXI_AWVALID;
  wire hp_smartconnect_0_M00_AXI_BREADY;
  wire [1:0]hp_smartconnect_0_M00_AXI_BRESP;
  wire hp_smartconnect_0_M00_AXI_BVALID;
  wire [63:0]hp_smartconnect_0_M00_AXI_RDATA;
  wire hp_smartconnect_0_M00_AXI_RLAST;
  wire hp_smartconnect_0_M00_AXI_RREADY;
  wire [1:0]hp_smartconnect_0_M00_AXI_RRESP;
  wire hp_smartconnect_0_M00_AXI_RVALID;
  wire [63:0]hp_smartconnect_0_M00_AXI_WDATA;
  wire hp_smartconnect_0_M00_AXI_WLAST;
  wire hp_smartconnect_0_M00_AXI_WREADY;
  wire [7:0]hp_smartconnect_0_M00_AXI_WSTRB;
  wire hp_smartconnect_0_M00_AXI_WVALID;
  wire [11:0]laser_axi_regs_0_adc_sample_rd_addr;
  wire laser_axi_regs_0_adc_sample_rd_en;
  wire laser_axi_regs_0_pl_soft_reset_hold;
  (* CONN_BUS_INFO = "m1_axis_bridge_0_M_AXIS1 xilinx.com:interface:axis:1.0 None TDATA" *) (* DONT_TOUCH *) wire [31:0]m1_axis_bridge_0_M_AXIS1_TDATA;
  (* CONN_BUS_INFO = "m1_axis_bridge_0_M_AXIS1 xilinx.com:interface:axis:1.0 None TKEEP" *) (* DONT_TOUCH *) wire [3:0]m1_axis_bridge_0_M_AXIS1_TKEEP;
  (* CONN_BUS_INFO = "m1_axis_bridge_0_M_AXIS1 xilinx.com:interface:axis:1.0 None TLAST" *) (* DONT_TOUCH *) wire m1_axis_bridge_0_M_AXIS1_TLAST;
  (* CONN_BUS_INFO = "m1_axis_bridge_0_M_AXIS1 xilinx.com:interface:axis:1.0 None TREADY" *) (* DONT_TOUCH *) wire m1_axis_bridge_0_M_AXIS1_TREADY;
  (* CONN_BUS_INFO = "m1_axis_bridge_0_M_AXIS1 xilinx.com:interface:axis:1.0 None TVALID" *) (* DONT_TOUCH *) wire m1_axis_bridge_0_M_AXIS1_TVALID;
  wire [31:0]m1_pl_axis_tdata;
  wire [3:0]m1_pl_axis_tkeep;
  wire m1_pl_axis_tlast;
  wire m1_pl_axis_tready;
  wire m1_pl_axis_tvalid;
  wire pl_capture_logic_0_ADC_CLK;
  wire pl_capture_logic_0_ADC_CSB;
  wire pl_capture_logic_0_ADC_OEB;
  wire pl_capture_logic_0_ADC_PDWN;
  wire pl_capture_logic_0_ADC_SCLK;
  wire pl_capture_logic_0_RXD_LAYSER1;
  wire pl_capture_logic_0_RXD_LAYSER2;
  wire pl_capture_logic_0_RXD_LAYSER3;
  wire pl_capture_logic_0_RXD_LAYSER4;
  wire pl_capture_logic_0_RXD_LAYSER5;
  wire pl_capture_logic_0_RXD_TEMPERATURE;
  wire [31:0]pl_capture_logic_0_ps_adc_a_filt_pp;
  wire [31:0]pl_capture_logic_0_ps_adc_a_raw_pp;
  wire [31:0]pl_capture_logic_0_ps_adc_b_filt_pp;
  wire [31:0]pl_capture_logic_0_ps_adc_b_raw_pp;
  wire [31:0]pl_capture_logic_0_ps_adc_sample_rd_data;
  wire [31:0]pl_capture_logic_0_ps_frame_id;
  wire [31:0]pl_capture_logic_0_ps_laser1_um;
  wire [31:0]pl_capture_logic_0_ps_laser2_um;
  wire [31:0]pl_capture_logic_0_ps_laser3_um;
  wire [31:0]pl_capture_logic_0_ps_laser4_um;
  wire [31:0]pl_capture_logic_0_ps_laser5_um;
  wire [5:0]pl_capture_logic_0_ps_sensor_crc_error;
  wire [5:0]pl_capture_logic_0_ps_sensor_frame_error;
  wire [5:0]pl_capture_logic_0_ps_sensor_timeout_error;
  wire [5:0]pl_capture_logic_0_ps_sensor_valid_seen;
  wire [15:0]pl_capture_logic_0_ps_temperature_x10;
  wire [14:0]processing_system7_0_DDR_ADDR;
  wire [2:0]processing_system7_0_DDR_BA;
  wire processing_system7_0_DDR_CAS_N;
  wire processing_system7_0_DDR_CKE;
  wire processing_system7_0_DDR_CK_N;
  wire processing_system7_0_DDR_CK_P;
  wire processing_system7_0_DDR_CS_N;
  wire [3:0]processing_system7_0_DDR_DM;
  wire [31:0]processing_system7_0_DDR_DQ;
  wire [3:0]processing_system7_0_DDR_DQS_N;
  wire [3:0]processing_system7_0_DDR_DQS_P;
  wire processing_system7_0_DDR_ODT;
  wire processing_system7_0_DDR_RAS_N;
  wire processing_system7_0_DDR_RESET_N;
  wire processing_system7_0_DDR_WE_N;
  wire processing_system7_0_FIXED_IO_DDR_VRN;
  wire processing_system7_0_FIXED_IO_DDR_VRP;
  wire [53:0]processing_system7_0_FIXED_IO_MIO;
  wire processing_system7_0_FIXED_IO_PS_CLK;
  wire processing_system7_0_FIXED_IO_PS_PORB;
  wire processing_system7_0_FIXED_IO_PS_SRSTB;
  wire [31:0]processing_system7_0_M_AXI_GP0_ARADDR;
  wire [1:0]processing_system7_0_M_AXI_GP0_ARBURST;
  wire [3:0]processing_system7_0_M_AXI_GP0_ARCACHE;
  wire [11:0]processing_system7_0_M_AXI_GP0_ARID;
  wire [3:0]processing_system7_0_M_AXI_GP0_ARLEN;
  wire [1:0]processing_system7_0_M_AXI_GP0_ARLOCK;
  wire [2:0]processing_system7_0_M_AXI_GP0_ARPROT;
  wire [3:0]processing_system7_0_M_AXI_GP0_ARQOS;
  wire processing_system7_0_M_AXI_GP0_ARREADY;
  wire [2:0]processing_system7_0_M_AXI_GP0_ARSIZE;
  wire processing_system7_0_M_AXI_GP0_ARVALID;
  wire [31:0]processing_system7_0_M_AXI_GP0_AWADDR;
  wire [1:0]processing_system7_0_M_AXI_GP0_AWBURST;
  wire [3:0]processing_system7_0_M_AXI_GP0_AWCACHE;
  wire [11:0]processing_system7_0_M_AXI_GP0_AWID;
  wire [3:0]processing_system7_0_M_AXI_GP0_AWLEN;
  wire [1:0]processing_system7_0_M_AXI_GP0_AWLOCK;
  wire [2:0]processing_system7_0_M_AXI_GP0_AWPROT;
  wire [3:0]processing_system7_0_M_AXI_GP0_AWQOS;
  wire processing_system7_0_M_AXI_GP0_AWREADY;
  wire [2:0]processing_system7_0_M_AXI_GP0_AWSIZE;
  wire processing_system7_0_M_AXI_GP0_AWVALID;
  wire [11:0]processing_system7_0_M_AXI_GP0_BID;
  wire processing_system7_0_M_AXI_GP0_BREADY;
  wire [1:0]processing_system7_0_M_AXI_GP0_BRESP;
  wire processing_system7_0_M_AXI_GP0_BVALID;
  wire [31:0]processing_system7_0_M_AXI_GP0_RDATA;
  wire [11:0]processing_system7_0_M_AXI_GP0_RID;
  wire processing_system7_0_M_AXI_GP0_RLAST;
  wire processing_system7_0_M_AXI_GP0_RREADY;
  wire [1:0]processing_system7_0_M_AXI_GP0_RRESP;
  wire processing_system7_0_M_AXI_GP0_RVALID;
  wire [31:0]processing_system7_0_M_AXI_GP0_WDATA;
  wire [11:0]processing_system7_0_M_AXI_GP0_WID;
  wire processing_system7_0_M_AXI_GP0_WLAST;
  wire processing_system7_0_M_AXI_GP0_WREADY;
  wire [3:0]processing_system7_0_M_AXI_GP0_WSTRB;
  wire processing_system7_0_M_AXI_GP0_WVALID;
  wire [5:0]smartconnect_0_M00_AXI_ARADDR;
  wire smartconnect_0_M00_AXI_ARREADY;
  wire smartconnect_0_M00_AXI_ARVALID;
  wire [5:0]smartconnect_0_M00_AXI_AWADDR;
  wire smartconnect_0_M00_AXI_AWREADY;
  wire smartconnect_0_M00_AXI_AWVALID;
  wire smartconnect_0_M00_AXI_BREADY;
  wire [1:0]smartconnect_0_M00_AXI_BRESP;
  wire smartconnect_0_M00_AXI_BVALID;
  wire [31:0]smartconnect_0_M00_AXI_RDATA;
  wire smartconnect_0_M00_AXI_RREADY;
  wire [1:0]smartconnect_0_M00_AXI_RRESP;
  wire smartconnect_0_M00_AXI_RVALID;
  wire [31:0]smartconnect_0_M00_AXI_WDATA;
  wire smartconnect_0_M00_AXI_WREADY;
  wire [3:0]smartconnect_0_M00_AXI_WSTRB;
  wire smartconnect_0_M00_AXI_WVALID;
  wire [9:0]smartconnect_0_M01_AXI_ARADDR;
  wire smartconnect_0_M01_AXI_ARREADY;
  wire smartconnect_0_M01_AXI_ARVALID;
  wire [9:0]smartconnect_0_M01_AXI_AWADDR;
  wire smartconnect_0_M01_AXI_AWREADY;
  wire smartconnect_0_M01_AXI_AWVALID;
  wire smartconnect_0_M01_AXI_BREADY;
  wire [1:0]smartconnect_0_M01_AXI_BRESP;
  wire smartconnect_0_M01_AXI_BVALID;
  wire [31:0]smartconnect_0_M01_AXI_RDATA;
  wire smartconnect_0_M01_AXI_RREADY;
  wire [1:0]smartconnect_0_M01_AXI_RRESP;
  wire smartconnect_0_M01_AXI_RVALID;
  wire [31:0]smartconnect_0_M01_AXI_WDATA;
  wire smartconnect_0_M01_AXI_WREADY;
  wire smartconnect_0_M01_AXI_WVALID;

  assign ADC_CLK = pl_capture_logic_0_ADC_CLK;
  assign ADC_CSB = pl_capture_logic_0_ADC_CSB;
  assign ADC_DCOA_0_1 = ADC_DCOA;
  assign ADC_DCOB_0_1 = ADC_DCOB;
  assign ADC_INA_0_1 = ADC_INA[15:0];
  assign ADC_INB_0_1 = ADC_INB[15:0];
  assign ADC_OEB = pl_capture_logic_0_ADC_OEB;
  assign ADC_ORA_0_1 = ADC_ORA;
  assign ADC_ORB_0_1 = ADC_ORB;
  assign ADC_PDWN = pl_capture_logic_0_ADC_PDWN;
  assign ADC_SCLK = pl_capture_logic_0_ADC_SCLK;
  assign CLK_50M_0_1 = CLK_50M;
  assign RST_N_1 = RST_N;
  assign RXD_LAYSER1 = pl_capture_logic_0_RXD_LAYSER1;
  assign RXD_LAYSER2 = pl_capture_logic_0_RXD_LAYSER2;
  assign RXD_LAYSER3 = pl_capture_logic_0_RXD_LAYSER3;
  assign RXD_LAYSER4 = pl_capture_logic_0_RXD_LAYSER4;
  assign RXD_LAYSER5 = pl_capture_logic_0_RXD_LAYSER5;
  assign RXD_TEMPERATURE = pl_capture_logic_0_RXD_TEMPERATURE;
  assign TXD_LAYSER1_0_1 = TXD_LAYSER1;
  assign TXD_LAYSER2_0_1 = TXD_LAYSER2;
  assign TXD_LAYSER3_0_1 = TXD_LAYSER3;
  assign TXD_LAYSER4_0_1 = TXD_LAYSER4;
  assign TXD_LAYSER5_0_1 = TXD_LAYSER5;
  assign TXD_TEMPERATURE_0_1 = TXD_TEMPERATURE;
  ps_system_axi_dma_0_0 axi_dma_0
       (.axi_resetn(RST_N_1),
        .m_axi_s2mm_aclk(CLK_50M_0_1),
        .m_axi_s2mm_awaddr(axi_dma_0_M_AXI_S2MM_AWADDR),
        .m_axi_s2mm_awburst(axi_dma_0_M_AXI_S2MM_AWBURST),
        .m_axi_s2mm_awcache(axi_dma_0_M_AXI_S2MM_AWCACHE),
        .m_axi_s2mm_awlen(axi_dma_0_M_AXI_S2MM_AWLEN),
        .m_axi_s2mm_awprot(axi_dma_0_M_AXI_S2MM_AWPROT),
        .m_axi_s2mm_awready(axi_dma_0_M_AXI_S2MM_AWREADY),
        .m_axi_s2mm_awsize(axi_dma_0_M_AXI_S2MM_AWSIZE),
        .m_axi_s2mm_awvalid(axi_dma_0_M_AXI_S2MM_AWVALID),
        .m_axi_s2mm_bready(axi_dma_0_M_AXI_S2MM_BREADY),
        .m_axi_s2mm_bresp(axi_dma_0_M_AXI_S2MM_BRESP),
        .m_axi_s2mm_bvalid(axi_dma_0_M_AXI_S2MM_BVALID),
        .m_axi_s2mm_wdata(axi_dma_0_M_AXI_S2MM_WDATA),
        .m_axi_s2mm_wlast(axi_dma_0_M_AXI_S2MM_WLAST),
        .m_axi_s2mm_wready(axi_dma_0_M_AXI_S2MM_WREADY),
        .m_axi_s2mm_wstrb(axi_dma_0_M_AXI_S2MM_WSTRB),
        .m_axi_s2mm_wvalid(axi_dma_0_M_AXI_S2MM_WVALID),
        .m_axi_sg_aclk(CLK_50M_0_1),
        .m_axi_sg_araddr(axi_dma_0_M_AXI_SG_ARADDR),
        .m_axi_sg_arburst(axi_dma_0_M_AXI_SG_ARBURST),
        .m_axi_sg_arcache(axi_dma_0_M_AXI_SG_ARCACHE),
        .m_axi_sg_arlen(axi_dma_0_M_AXI_SG_ARLEN),
        .m_axi_sg_arprot(axi_dma_0_M_AXI_SG_ARPROT),
        .m_axi_sg_arready(axi_dma_0_M_AXI_SG_ARREADY),
        .m_axi_sg_arsize(axi_dma_0_M_AXI_SG_ARSIZE),
        .m_axi_sg_arvalid(axi_dma_0_M_AXI_SG_ARVALID),
        .m_axi_sg_awaddr(axi_dma_0_M_AXI_SG_AWADDR),
        .m_axi_sg_awburst(axi_dma_0_M_AXI_SG_AWBURST),
        .m_axi_sg_awcache(axi_dma_0_M_AXI_SG_AWCACHE),
        .m_axi_sg_awlen(axi_dma_0_M_AXI_SG_AWLEN),
        .m_axi_sg_awprot(axi_dma_0_M_AXI_SG_AWPROT),
        .m_axi_sg_awready(axi_dma_0_M_AXI_SG_AWREADY),
        .m_axi_sg_awsize(axi_dma_0_M_AXI_SG_AWSIZE),
        .m_axi_sg_awvalid(axi_dma_0_M_AXI_SG_AWVALID),
        .m_axi_sg_bready(axi_dma_0_M_AXI_SG_BREADY),
        .m_axi_sg_bresp(axi_dma_0_M_AXI_SG_BRESP),
        .m_axi_sg_bvalid(axi_dma_0_M_AXI_SG_BVALID),
        .m_axi_sg_rdata(axi_dma_0_M_AXI_SG_RDATA),
        .m_axi_sg_rlast(axi_dma_0_M_AXI_SG_RLAST),
        .m_axi_sg_rready(axi_dma_0_M_AXI_SG_RREADY),
        .m_axi_sg_rresp(axi_dma_0_M_AXI_SG_RRESP),
        .m_axi_sg_rvalid(axi_dma_0_M_AXI_SG_RVALID),
        .m_axi_sg_wdata(axi_dma_0_M_AXI_SG_WDATA),
        .m_axi_sg_wlast(axi_dma_0_M_AXI_SG_WLAST),
        .m_axi_sg_wready(axi_dma_0_M_AXI_SG_WREADY),
        .m_axi_sg_wstrb(axi_dma_0_M_AXI_SG_WSTRB),
        .m_axi_sg_wvalid(axi_dma_0_M_AXI_SG_WVALID),
        .s_axi_lite_aclk(CLK_50M_0_1),
        .s_axi_lite_araddr(smartconnect_0_M01_AXI_ARADDR),
        .s_axi_lite_arready(smartconnect_0_M01_AXI_ARREADY),
        .s_axi_lite_arvalid(smartconnect_0_M01_AXI_ARVALID),
        .s_axi_lite_awaddr(smartconnect_0_M01_AXI_AWADDR),
        .s_axi_lite_awready(smartconnect_0_M01_AXI_AWREADY),
        .s_axi_lite_awvalid(smartconnect_0_M01_AXI_AWVALID),
        .s_axi_lite_bready(smartconnect_0_M01_AXI_BREADY),
        .s_axi_lite_bresp(smartconnect_0_M01_AXI_BRESP),
        .s_axi_lite_bvalid(smartconnect_0_M01_AXI_BVALID),
        .s_axi_lite_rdata(smartconnect_0_M01_AXI_RDATA),
        .s_axi_lite_rready(smartconnect_0_M01_AXI_RREADY),
        .s_axi_lite_rresp(smartconnect_0_M01_AXI_RRESP),
        .s_axi_lite_rvalid(smartconnect_0_M01_AXI_RVALID),
        .s_axi_lite_wdata(smartconnect_0_M01_AXI_WDATA),
        .s_axi_lite_wready(smartconnect_0_M01_AXI_WREADY),
        .s_axi_lite_wvalid(smartconnect_0_M01_AXI_WVALID),
        .s_axis_s2mm_tdata(m1_axis_bridge_0_M_AXIS1_TDATA),
        .s_axis_s2mm_tkeep(m1_axis_bridge_0_M_AXIS1_TKEEP),
        .s_axis_s2mm_tlast(m1_axis_bridge_0_M_AXIS1_TLAST),
        .s_axis_s2mm_tready(m1_axis_bridge_0_M_AXIS1_TREADY),
        .s_axis_s2mm_tvalid(m1_axis_bridge_0_M_AXIS1_TVALID));
  ps_system_hp_smartconnect_0_0 hp_smartconnect_0
       (.M00_AXI_araddr(hp_smartconnect_0_M00_AXI_ARADDR),
        .M00_AXI_arburst(hp_smartconnect_0_M00_AXI_ARBURST),
        .M00_AXI_arcache(hp_smartconnect_0_M00_AXI_ARCACHE),
        .M00_AXI_arlen(hp_smartconnect_0_M00_AXI_ARLEN),
        .M00_AXI_arlock(hp_smartconnect_0_M00_AXI_ARLOCK),
        .M00_AXI_arprot(hp_smartconnect_0_M00_AXI_ARPROT),
        .M00_AXI_arqos(hp_smartconnect_0_M00_AXI_ARQOS),
        .M00_AXI_arready(hp_smartconnect_0_M00_AXI_ARREADY),
        .M00_AXI_arsize(hp_smartconnect_0_M00_AXI_ARSIZE),
        .M00_AXI_arvalid(hp_smartconnect_0_M00_AXI_ARVALID),
        .M00_AXI_awaddr(hp_smartconnect_0_M00_AXI_AWADDR),
        .M00_AXI_awburst(hp_smartconnect_0_M00_AXI_AWBURST),
        .M00_AXI_awcache(hp_smartconnect_0_M00_AXI_AWCACHE),
        .M00_AXI_awlen(hp_smartconnect_0_M00_AXI_AWLEN),
        .M00_AXI_awlock(hp_smartconnect_0_M00_AXI_AWLOCK),
        .M00_AXI_awprot(hp_smartconnect_0_M00_AXI_AWPROT),
        .M00_AXI_awqos(hp_smartconnect_0_M00_AXI_AWQOS),
        .M00_AXI_awready(hp_smartconnect_0_M00_AXI_AWREADY),
        .M00_AXI_awsize(hp_smartconnect_0_M00_AXI_AWSIZE),
        .M00_AXI_awvalid(hp_smartconnect_0_M00_AXI_AWVALID),
        .M00_AXI_bready(hp_smartconnect_0_M00_AXI_BREADY),
        .M00_AXI_bresp(hp_smartconnect_0_M00_AXI_BRESP),
        .M00_AXI_bvalid(hp_smartconnect_0_M00_AXI_BVALID),
        .M00_AXI_rdata(hp_smartconnect_0_M00_AXI_RDATA),
        .M00_AXI_rlast(hp_smartconnect_0_M00_AXI_RLAST),
        .M00_AXI_rready(hp_smartconnect_0_M00_AXI_RREADY),
        .M00_AXI_rresp(hp_smartconnect_0_M00_AXI_RRESP),
        .M00_AXI_rvalid(hp_smartconnect_0_M00_AXI_RVALID),
        .M00_AXI_wdata(hp_smartconnect_0_M00_AXI_WDATA),
        .M00_AXI_wlast(hp_smartconnect_0_M00_AXI_WLAST),
        .M00_AXI_wready(hp_smartconnect_0_M00_AXI_WREADY),
        .M00_AXI_wstrb(hp_smartconnect_0_M00_AXI_WSTRB),
        .M00_AXI_wvalid(hp_smartconnect_0_M00_AXI_WVALID),
        .S00_AXI_awaddr(axi_dma_0_M_AXI_S2MM_AWADDR),
        .S00_AXI_awburst(axi_dma_0_M_AXI_S2MM_AWBURST),
        .S00_AXI_awcache(axi_dma_0_M_AXI_S2MM_AWCACHE),
        .S00_AXI_awlen(axi_dma_0_M_AXI_S2MM_AWLEN),
        .S00_AXI_awlock(1'b0),
        .S00_AXI_awprot(axi_dma_0_M_AXI_S2MM_AWPROT),
        .S00_AXI_awqos({1'b0,1'b0,1'b0,1'b0}),
        .S00_AXI_awready(axi_dma_0_M_AXI_S2MM_AWREADY),
        .S00_AXI_awsize(axi_dma_0_M_AXI_S2MM_AWSIZE),
        .S00_AXI_awvalid(axi_dma_0_M_AXI_S2MM_AWVALID),
        .S00_AXI_bready(axi_dma_0_M_AXI_S2MM_BREADY),
        .S00_AXI_bresp(axi_dma_0_M_AXI_S2MM_BRESP),
        .S00_AXI_bvalid(axi_dma_0_M_AXI_S2MM_BVALID),
        .S00_AXI_wdata(axi_dma_0_M_AXI_S2MM_WDATA),
        .S00_AXI_wlast(axi_dma_0_M_AXI_S2MM_WLAST),
        .S00_AXI_wready(axi_dma_0_M_AXI_S2MM_WREADY),
        .S00_AXI_wstrb(axi_dma_0_M_AXI_S2MM_WSTRB),
        .S00_AXI_wvalid(axi_dma_0_M_AXI_S2MM_WVALID),
        .S01_AXI_araddr(axi_dma_0_M_AXI_SG_ARADDR),
        .S01_AXI_arburst(axi_dma_0_M_AXI_SG_ARBURST),
        .S01_AXI_arcache(axi_dma_0_M_AXI_SG_ARCACHE),
        .S01_AXI_arlen(axi_dma_0_M_AXI_SG_ARLEN),
        .S01_AXI_arlock(1'b0),
        .S01_AXI_arprot(axi_dma_0_M_AXI_SG_ARPROT),
        .S01_AXI_arqos({1'b0,1'b0,1'b0,1'b0}),
        .S01_AXI_arready(axi_dma_0_M_AXI_SG_ARREADY),
        .S01_AXI_arsize(axi_dma_0_M_AXI_SG_ARSIZE),
        .S01_AXI_arvalid(axi_dma_0_M_AXI_SG_ARVALID),
        .S01_AXI_awaddr(axi_dma_0_M_AXI_SG_AWADDR),
        .S01_AXI_awburst(axi_dma_0_M_AXI_SG_AWBURST),
        .S01_AXI_awcache(axi_dma_0_M_AXI_SG_AWCACHE),
        .S01_AXI_awlen(axi_dma_0_M_AXI_SG_AWLEN),
        .S01_AXI_awlock(1'b0),
        .S01_AXI_awprot(axi_dma_0_M_AXI_SG_AWPROT),
        .S01_AXI_awqos({1'b0,1'b0,1'b0,1'b0}),
        .S01_AXI_awready(axi_dma_0_M_AXI_SG_AWREADY),
        .S01_AXI_awsize(axi_dma_0_M_AXI_SG_AWSIZE),
        .S01_AXI_awvalid(axi_dma_0_M_AXI_SG_AWVALID),
        .S01_AXI_bready(axi_dma_0_M_AXI_SG_BREADY),
        .S01_AXI_bresp(axi_dma_0_M_AXI_SG_BRESP),
        .S01_AXI_bvalid(axi_dma_0_M_AXI_SG_BVALID),
        .S01_AXI_rdata(axi_dma_0_M_AXI_SG_RDATA),
        .S01_AXI_rlast(axi_dma_0_M_AXI_SG_RLAST),
        .S01_AXI_rready(axi_dma_0_M_AXI_SG_RREADY),
        .S01_AXI_rresp(axi_dma_0_M_AXI_SG_RRESP),
        .S01_AXI_rvalid(axi_dma_0_M_AXI_SG_RVALID),
        .S01_AXI_wdata(axi_dma_0_M_AXI_SG_WDATA),
        .S01_AXI_wlast(axi_dma_0_M_AXI_SG_WLAST),
        .S01_AXI_wready(axi_dma_0_M_AXI_SG_WREADY),
        .S01_AXI_wstrb(axi_dma_0_M_AXI_SG_WSTRB),
        .S01_AXI_wvalid(axi_dma_0_M_AXI_SG_WVALID),
        .aclk(CLK_50M_0_1),
        .aresetn(RST_N_1));
  ps_system_laser_axi_regs_0_0 laser_axi_regs_0
       (.S_AXI_ACLK(CLK_50M_0_1),
        .S_AXI_ARADDR(smartconnect_0_M00_AXI_ARADDR),
        .S_AXI_ARESETN(RST_N_1),
        .S_AXI_ARREADY(smartconnect_0_M00_AXI_ARREADY),
        .S_AXI_ARVALID(smartconnect_0_M00_AXI_ARVALID),
        .S_AXI_AWADDR(smartconnect_0_M00_AXI_AWADDR),
        .S_AXI_AWREADY(smartconnect_0_M00_AXI_AWREADY),
        .S_AXI_AWVALID(smartconnect_0_M00_AXI_AWVALID),
        .S_AXI_BREADY(smartconnect_0_M00_AXI_BREADY),
        .S_AXI_BRESP(smartconnect_0_M00_AXI_BRESP),
        .S_AXI_BVALID(smartconnect_0_M00_AXI_BVALID),
        .S_AXI_RDATA(smartconnect_0_M00_AXI_RDATA),
        .S_AXI_RREADY(smartconnect_0_M00_AXI_RREADY),
        .S_AXI_RRESP(smartconnect_0_M00_AXI_RRESP),
        .S_AXI_RVALID(smartconnect_0_M00_AXI_RVALID),
        .S_AXI_WDATA(smartconnect_0_M00_AXI_WDATA),
        .S_AXI_WREADY(smartconnect_0_M00_AXI_WREADY),
        .S_AXI_WSTRB(smartconnect_0_M00_AXI_WSTRB),
        .S_AXI_WVALID(smartconnect_0_M00_AXI_WVALID),
        .adc_a_filt_pp(pl_capture_logic_0_ps_adc_a_filt_pp),
        .adc_a_raw_pp(pl_capture_logic_0_ps_adc_a_raw_pp),
        .adc_b_filt_pp(pl_capture_logic_0_ps_adc_b_filt_pp),
        .adc_b_raw_pp(pl_capture_logic_0_ps_adc_b_raw_pp),
        .adc_sample_rd_addr(laser_axi_regs_0_adc_sample_rd_addr),
        .adc_sample_rd_data(pl_capture_logic_0_ps_adc_sample_rd_data),
        .adc_sample_rd_en(laser_axi_regs_0_adc_sample_rd_en),
        .frame_id(pl_capture_logic_0_ps_frame_id),
        .laser1_um(pl_capture_logic_0_ps_laser1_um),
        .laser2_um(pl_capture_logic_0_ps_laser2_um),
        .laser3_um(pl_capture_logic_0_ps_laser3_um),
        .laser4_um(pl_capture_logic_0_ps_laser4_um),
        .laser5_um(pl_capture_logic_0_ps_laser5_um),
        .pl_soft_reset_hold(laser_axi_regs_0_pl_soft_reset_hold),
        .sensor_crc_error(pl_capture_logic_0_ps_sensor_crc_error),
        .sensor_frame_error(pl_capture_logic_0_ps_sensor_frame_error),
        .sensor_timeout_error(pl_capture_logic_0_ps_sensor_timeout_error),
        .sensor_valid_seen(pl_capture_logic_0_ps_sensor_valid_seen),
        .temperature_x10(pl_capture_logic_0_ps_temperature_x10));
  ps_system_m1_axis_bridge_0_1 m1_axis_bridge_0
       (.aclk(CLK_50M_0_1),
        .aresetn(RST_N_1),
        .in_data(m1_pl_axis_tdata),
        .in_keep(m1_pl_axis_tkeep),
        .in_last(m1_pl_axis_tlast),
        .in_valid(m1_pl_axis_tvalid),
        .m_axis_tdata(m1_axis_bridge_0_M_AXIS1_TDATA),
        .m_axis_tkeep(m1_axis_bridge_0_M_AXIS1_TKEEP),
        .m_axis_tlast(m1_axis_bridge_0_M_AXIS1_TLAST),
        .m_axis_tready(m1_axis_bridge_0_M_AXIS1_TREADY),
        .m_axis_tvalid(m1_axis_bridge_0_M_AXIS1_TVALID),
        .out_ready(m1_pl_axis_tready));
  ps_system_pl_capture_logic_0_0 pl_capture_logic_0
       (.ADC_CLK(pl_capture_logic_0_ADC_CLK),
        .ADC_CSB(pl_capture_logic_0_ADC_CSB),
        .ADC_DCOA(ADC_DCOA_0_1),
        .ADC_DCOB(ADC_DCOB_0_1),
        .ADC_INA(ADC_INA_0_1),
        .ADC_INB(ADC_INB_0_1),
        .ADC_OEB(pl_capture_logic_0_ADC_OEB),
        .ADC_ORA(ADC_ORA_0_1),
        .ADC_ORB(ADC_ORB_0_1),
        .ADC_PDWN(pl_capture_logic_0_ADC_PDWN),
        .ADC_SCLK(pl_capture_logic_0_ADC_SCLK),
        .ADC_SDIO(ADC_SDIO),
        .CLK_50M(CLK_50M_0_1),
        .M_AXIS_FRAME_TDATA(m1_pl_axis_tdata),
        .M_AXIS_FRAME_TKEEP(m1_pl_axis_tkeep),
        .M_AXIS_FRAME_TLAST(m1_pl_axis_tlast),
        .M_AXIS_FRAME_TREADY(m1_pl_axis_tready),
        .M_AXIS_FRAME_TVALID(m1_pl_axis_tvalid),
        .RST_N(RST_N_1),
        .RXD_LAYSER1(pl_capture_logic_0_RXD_LAYSER1),
        .RXD_LAYSER2(pl_capture_logic_0_RXD_LAYSER2),
        .RXD_LAYSER3(pl_capture_logic_0_RXD_LAYSER3),
        .RXD_LAYSER4(pl_capture_logic_0_RXD_LAYSER4),
        .RXD_LAYSER5(pl_capture_logic_0_RXD_LAYSER5),
        .RXD_TEMPERATURE(pl_capture_logic_0_RXD_TEMPERATURE),
        .TXD_LAYSER1(TXD_LAYSER1_0_1),
        .TXD_LAYSER2(TXD_LAYSER2_0_1),
        .TXD_LAYSER3(TXD_LAYSER3_0_1),
        .TXD_LAYSER4(TXD_LAYSER4_0_1),
        .TXD_LAYSER5(TXD_LAYSER5_0_1),
        .TXD_TEMPERATURE(TXD_TEMPERATURE_0_1),
        .ps_adc_a_filt_pp(pl_capture_logic_0_ps_adc_a_filt_pp),
        .ps_adc_a_raw_pp(pl_capture_logic_0_ps_adc_a_raw_pp),
        .ps_adc_b_filt_pp(pl_capture_logic_0_ps_adc_b_filt_pp),
        .ps_adc_b_raw_pp(pl_capture_logic_0_ps_adc_b_raw_pp),
        .ps_adc_sample_rd_addr(laser_axi_regs_0_adc_sample_rd_addr),
        .ps_adc_sample_rd_data(pl_capture_logic_0_ps_adc_sample_rd_data),
        .ps_adc_sample_rd_en(laser_axi_regs_0_adc_sample_rd_en),
        .ps_frame_id(pl_capture_logic_0_ps_frame_id),
        .ps_laser1_um(pl_capture_logic_0_ps_laser1_um),
        .ps_laser2_um(pl_capture_logic_0_ps_laser2_um),
        .ps_laser3_um(pl_capture_logic_0_ps_laser3_um),
        .ps_laser4_um(pl_capture_logic_0_ps_laser4_um),
        .ps_laser5_um(pl_capture_logic_0_ps_laser5_um),
        .ps_pl_reset_hold(laser_axi_regs_0_pl_soft_reset_hold),
        .ps_sensor_crc_error(pl_capture_logic_0_ps_sensor_crc_error),
        .ps_sensor_frame_error(pl_capture_logic_0_ps_sensor_frame_error),
        .ps_sensor_timeout_error(pl_capture_logic_0_ps_sensor_timeout_error),
        .ps_sensor_valid_seen(pl_capture_logic_0_ps_sensor_valid_seen),
        .ps_temperature_x10(pl_capture_logic_0_ps_temperature_x10));
  ps_system_processing_system7_0_0 processing_system7_0
       (.DDR_Addr(DDR_addr[14:0]),
        .DDR_BankAddr(DDR_ba[2:0]),
        .DDR_CAS_n(DDR_cas_n),
        .DDR_CKE(DDR_cke),
        .DDR_CS_n(DDR_cs_n),
        .DDR_Clk(DDR_ck_p),
        .DDR_Clk_n(DDR_ck_n),
        .DDR_DM(DDR_dm[3:0]),
        .DDR_DQ(DDR_dq[31:0]),
        .DDR_DQS(DDR_dqs_p[3:0]),
        .DDR_DQS_n(DDR_dqs_n[3:0]),
        .DDR_DRSTB(DDR_reset_n),
        .DDR_ODT(DDR_odt),
        .DDR_RAS_n(DDR_ras_n),
        .DDR_VRN(FIXED_IO_ddr_vrn),
        .DDR_VRP(FIXED_IO_ddr_vrp),
        .DDR_WEB(DDR_we_n),
        .MIO(FIXED_IO_mio[53:0]),
        .M_AXI_GP0_ACLK(CLK_50M_0_1),
        .M_AXI_GP0_ARADDR(processing_system7_0_M_AXI_GP0_ARADDR),
        .M_AXI_GP0_ARBURST(processing_system7_0_M_AXI_GP0_ARBURST),
        .M_AXI_GP0_ARCACHE(processing_system7_0_M_AXI_GP0_ARCACHE),
        .M_AXI_GP0_ARID(processing_system7_0_M_AXI_GP0_ARID),
        .M_AXI_GP0_ARLEN(processing_system7_0_M_AXI_GP0_ARLEN),
        .M_AXI_GP0_ARLOCK(processing_system7_0_M_AXI_GP0_ARLOCK),
        .M_AXI_GP0_ARPROT(processing_system7_0_M_AXI_GP0_ARPROT),
        .M_AXI_GP0_ARQOS(processing_system7_0_M_AXI_GP0_ARQOS),
        .M_AXI_GP0_ARREADY(processing_system7_0_M_AXI_GP0_ARREADY),
        .M_AXI_GP0_ARSIZE(processing_system7_0_M_AXI_GP0_ARSIZE),
        .M_AXI_GP0_ARVALID(processing_system7_0_M_AXI_GP0_ARVALID),
        .M_AXI_GP0_AWADDR(processing_system7_0_M_AXI_GP0_AWADDR),
        .M_AXI_GP0_AWBURST(processing_system7_0_M_AXI_GP0_AWBURST),
        .M_AXI_GP0_AWCACHE(processing_system7_0_M_AXI_GP0_AWCACHE),
        .M_AXI_GP0_AWID(processing_system7_0_M_AXI_GP0_AWID),
        .M_AXI_GP0_AWLEN(processing_system7_0_M_AXI_GP0_AWLEN),
        .M_AXI_GP0_AWLOCK(processing_system7_0_M_AXI_GP0_AWLOCK),
        .M_AXI_GP0_AWPROT(processing_system7_0_M_AXI_GP0_AWPROT),
        .M_AXI_GP0_AWQOS(processing_system7_0_M_AXI_GP0_AWQOS),
        .M_AXI_GP0_AWREADY(processing_system7_0_M_AXI_GP0_AWREADY),
        .M_AXI_GP0_AWSIZE(processing_system7_0_M_AXI_GP0_AWSIZE),
        .M_AXI_GP0_AWVALID(processing_system7_0_M_AXI_GP0_AWVALID),
        .M_AXI_GP0_BID(processing_system7_0_M_AXI_GP0_BID),
        .M_AXI_GP0_BREADY(processing_system7_0_M_AXI_GP0_BREADY),
        .M_AXI_GP0_BRESP(processing_system7_0_M_AXI_GP0_BRESP),
        .M_AXI_GP0_BVALID(processing_system7_0_M_AXI_GP0_BVALID),
        .M_AXI_GP0_RDATA(processing_system7_0_M_AXI_GP0_RDATA),
        .M_AXI_GP0_RID(processing_system7_0_M_AXI_GP0_RID),
        .M_AXI_GP0_RLAST(processing_system7_0_M_AXI_GP0_RLAST),
        .M_AXI_GP0_RREADY(processing_system7_0_M_AXI_GP0_RREADY),
        .M_AXI_GP0_RRESP(processing_system7_0_M_AXI_GP0_RRESP),
        .M_AXI_GP0_RVALID(processing_system7_0_M_AXI_GP0_RVALID),
        .M_AXI_GP0_WDATA(processing_system7_0_M_AXI_GP0_WDATA),
        .M_AXI_GP0_WID(processing_system7_0_M_AXI_GP0_WID),
        .M_AXI_GP0_WLAST(processing_system7_0_M_AXI_GP0_WLAST),
        .M_AXI_GP0_WREADY(processing_system7_0_M_AXI_GP0_WREADY),
        .M_AXI_GP0_WSTRB(processing_system7_0_M_AXI_GP0_WSTRB),
        .M_AXI_GP0_WVALID(processing_system7_0_M_AXI_GP0_WVALID),
        .PS_CLK(FIXED_IO_ps_clk),
        .PS_PORB(FIXED_IO_ps_porb),
        .PS_SRSTB(FIXED_IO_ps_srstb),
        .S_AXI_HP0_ACLK(CLK_50M_0_1),
        .S_AXI_HP0_ARADDR(hp_smartconnect_0_M00_AXI_ARADDR),
        .S_AXI_HP0_ARBURST(hp_smartconnect_0_M00_AXI_ARBURST),
        .S_AXI_HP0_ARCACHE(hp_smartconnect_0_M00_AXI_ARCACHE),
        .S_AXI_HP0_ARID({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .S_AXI_HP0_ARLEN(hp_smartconnect_0_M00_AXI_ARLEN),
        .S_AXI_HP0_ARLOCK(hp_smartconnect_0_M00_AXI_ARLOCK),
        .S_AXI_HP0_ARPROT(hp_smartconnect_0_M00_AXI_ARPROT),
        .S_AXI_HP0_ARQOS(hp_smartconnect_0_M00_AXI_ARQOS),
        .S_AXI_HP0_ARREADY(hp_smartconnect_0_M00_AXI_ARREADY),
        .S_AXI_HP0_ARSIZE(hp_smartconnect_0_M00_AXI_ARSIZE),
        .S_AXI_HP0_ARVALID(hp_smartconnect_0_M00_AXI_ARVALID),
        .S_AXI_HP0_AWADDR(hp_smartconnect_0_M00_AXI_AWADDR),
        .S_AXI_HP0_AWBURST(hp_smartconnect_0_M00_AXI_AWBURST),
        .S_AXI_HP0_AWCACHE(hp_smartconnect_0_M00_AXI_AWCACHE),
        .S_AXI_HP0_AWID({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .S_AXI_HP0_AWLEN(hp_smartconnect_0_M00_AXI_AWLEN),
        .S_AXI_HP0_AWLOCK(hp_smartconnect_0_M00_AXI_AWLOCK),
        .S_AXI_HP0_AWPROT(hp_smartconnect_0_M00_AXI_AWPROT),
        .S_AXI_HP0_AWQOS(hp_smartconnect_0_M00_AXI_AWQOS),
        .S_AXI_HP0_AWREADY(hp_smartconnect_0_M00_AXI_AWREADY),
        .S_AXI_HP0_AWSIZE(hp_smartconnect_0_M00_AXI_AWSIZE),
        .S_AXI_HP0_AWVALID(hp_smartconnect_0_M00_AXI_AWVALID),
        .S_AXI_HP0_BREADY(hp_smartconnect_0_M00_AXI_BREADY),
        .S_AXI_HP0_BRESP(hp_smartconnect_0_M00_AXI_BRESP),
        .S_AXI_HP0_BVALID(hp_smartconnect_0_M00_AXI_BVALID),
        .S_AXI_HP0_RDATA(hp_smartconnect_0_M00_AXI_RDATA),
        .S_AXI_HP0_RDISSUECAP1_EN(1'b0),
        .S_AXI_HP0_RLAST(hp_smartconnect_0_M00_AXI_RLAST),
        .S_AXI_HP0_RREADY(hp_smartconnect_0_M00_AXI_RREADY),
        .S_AXI_HP0_RRESP(hp_smartconnect_0_M00_AXI_RRESP),
        .S_AXI_HP0_RVALID(hp_smartconnect_0_M00_AXI_RVALID),
        .S_AXI_HP0_WDATA(hp_smartconnect_0_M00_AXI_WDATA),
        .S_AXI_HP0_WID({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
        .S_AXI_HP0_WLAST(hp_smartconnect_0_M00_AXI_WLAST),
        .S_AXI_HP0_WREADY(hp_smartconnect_0_M00_AXI_WREADY),
        .S_AXI_HP0_WRISSUECAP1_EN(1'b0),
        .S_AXI_HP0_WSTRB(hp_smartconnect_0_M00_AXI_WSTRB),
        .S_AXI_HP0_WVALID(hp_smartconnect_0_M00_AXI_WVALID));
  ps_system_smartconnect_0_0 smartconnect_0
       (.M00_AXI_araddr(smartconnect_0_M00_AXI_ARADDR),
        .M00_AXI_arready(smartconnect_0_M00_AXI_ARREADY),
        .M00_AXI_arvalid(smartconnect_0_M00_AXI_ARVALID),
        .M00_AXI_awaddr(smartconnect_0_M00_AXI_AWADDR),
        .M00_AXI_awready(smartconnect_0_M00_AXI_AWREADY),
        .M00_AXI_awvalid(smartconnect_0_M00_AXI_AWVALID),
        .M00_AXI_bready(smartconnect_0_M00_AXI_BREADY),
        .M00_AXI_bresp(smartconnect_0_M00_AXI_BRESP),
        .M00_AXI_bvalid(smartconnect_0_M00_AXI_BVALID),
        .M00_AXI_rdata(smartconnect_0_M00_AXI_RDATA),
        .M00_AXI_rready(smartconnect_0_M00_AXI_RREADY),
        .M00_AXI_rresp(smartconnect_0_M00_AXI_RRESP),
        .M00_AXI_rvalid(smartconnect_0_M00_AXI_RVALID),
        .M00_AXI_wdata(smartconnect_0_M00_AXI_WDATA),
        .M00_AXI_wready(smartconnect_0_M00_AXI_WREADY),
        .M00_AXI_wstrb(smartconnect_0_M00_AXI_WSTRB),
        .M00_AXI_wvalid(smartconnect_0_M00_AXI_WVALID),
        .M01_AXI_araddr(smartconnect_0_M01_AXI_ARADDR),
        .M01_AXI_arready(smartconnect_0_M01_AXI_ARREADY),
        .M01_AXI_arvalid(smartconnect_0_M01_AXI_ARVALID),
        .M01_AXI_awaddr(smartconnect_0_M01_AXI_AWADDR),
        .M01_AXI_awready(smartconnect_0_M01_AXI_AWREADY),
        .M01_AXI_awvalid(smartconnect_0_M01_AXI_AWVALID),
        .M01_AXI_bready(smartconnect_0_M01_AXI_BREADY),
        .M01_AXI_bresp(smartconnect_0_M01_AXI_BRESP),
        .M01_AXI_bvalid(smartconnect_0_M01_AXI_BVALID),
        .M01_AXI_rdata(smartconnect_0_M01_AXI_RDATA),
        .M01_AXI_rready(smartconnect_0_M01_AXI_RREADY),
        .M01_AXI_rresp(smartconnect_0_M01_AXI_RRESP),
        .M01_AXI_rvalid(smartconnect_0_M01_AXI_RVALID),
        .M01_AXI_wdata(smartconnect_0_M01_AXI_WDATA),
        .M01_AXI_wready(smartconnect_0_M01_AXI_WREADY),
        .M01_AXI_wvalid(smartconnect_0_M01_AXI_WVALID),
        .S00_AXI_araddr(processing_system7_0_M_AXI_GP0_ARADDR),
        .S00_AXI_arburst(processing_system7_0_M_AXI_GP0_ARBURST),
        .S00_AXI_arcache(processing_system7_0_M_AXI_GP0_ARCACHE),
        .S00_AXI_arid(processing_system7_0_M_AXI_GP0_ARID),
        .S00_AXI_arlen(processing_system7_0_M_AXI_GP0_ARLEN),
        .S00_AXI_arlock(processing_system7_0_M_AXI_GP0_ARLOCK),
        .S00_AXI_arprot(processing_system7_0_M_AXI_GP0_ARPROT),
        .S00_AXI_arqos(processing_system7_0_M_AXI_GP0_ARQOS),
        .S00_AXI_arready(processing_system7_0_M_AXI_GP0_ARREADY),
        .S00_AXI_arsize(processing_system7_0_M_AXI_GP0_ARSIZE),
        .S00_AXI_arvalid(processing_system7_0_M_AXI_GP0_ARVALID),
        .S00_AXI_awaddr(processing_system7_0_M_AXI_GP0_AWADDR),
        .S00_AXI_awburst(processing_system7_0_M_AXI_GP0_AWBURST),
        .S00_AXI_awcache(processing_system7_0_M_AXI_GP0_AWCACHE),
        .S00_AXI_awid(processing_system7_0_M_AXI_GP0_AWID),
        .S00_AXI_awlen(processing_system7_0_M_AXI_GP0_AWLEN),
        .S00_AXI_awlock(processing_system7_0_M_AXI_GP0_AWLOCK),
        .S00_AXI_awprot(processing_system7_0_M_AXI_GP0_AWPROT),
        .S00_AXI_awqos(processing_system7_0_M_AXI_GP0_AWQOS),
        .S00_AXI_awready(processing_system7_0_M_AXI_GP0_AWREADY),
        .S00_AXI_awsize(processing_system7_0_M_AXI_GP0_AWSIZE),
        .S00_AXI_awvalid(processing_system7_0_M_AXI_GP0_AWVALID),
        .S00_AXI_bid(processing_system7_0_M_AXI_GP0_BID),
        .S00_AXI_bready(processing_system7_0_M_AXI_GP0_BREADY),
        .S00_AXI_bresp(processing_system7_0_M_AXI_GP0_BRESP),
        .S00_AXI_bvalid(processing_system7_0_M_AXI_GP0_BVALID),
        .S00_AXI_rdata(processing_system7_0_M_AXI_GP0_RDATA),
        .S00_AXI_rid(processing_system7_0_M_AXI_GP0_RID),
        .S00_AXI_rlast(processing_system7_0_M_AXI_GP0_RLAST),
        .S00_AXI_rready(processing_system7_0_M_AXI_GP0_RREADY),
        .S00_AXI_rresp(processing_system7_0_M_AXI_GP0_RRESP),
        .S00_AXI_rvalid(processing_system7_0_M_AXI_GP0_RVALID),
        .S00_AXI_wdata(processing_system7_0_M_AXI_GP0_WDATA),
        .S00_AXI_wid(processing_system7_0_M_AXI_GP0_WID),
        .S00_AXI_wlast(processing_system7_0_M_AXI_GP0_WLAST),
        .S00_AXI_wready(processing_system7_0_M_AXI_GP0_WREADY),
        .S00_AXI_wstrb(processing_system7_0_M_AXI_GP0_WSTRB),
        .S00_AXI_wvalid(processing_system7_0_M_AXI_GP0_WVALID),
        .aclk(CLK_50M_0_1),
        .aresetn(RST_N_1));
  ps_system_system_ila_0_0 system_ila_0
       (.SLOT_0_AXI_araddr(axi_dma_0_M_AXI_SG_ARADDR),
        .SLOT_0_AXI_arcache(axi_dma_0_M_AXI_SG_ARCACHE),
        .SLOT_0_AXI_arlen(axi_dma_0_M_AXI_SG_ARLEN),
        .SLOT_0_AXI_arprot(axi_dma_0_M_AXI_SG_ARPROT),
        .SLOT_0_AXI_arready(axi_dma_0_M_AXI_SG_ARREADY),
        .SLOT_0_AXI_arsize(axi_dma_0_M_AXI_SG_ARSIZE),
        .SLOT_0_AXI_arvalid(axi_dma_0_M_AXI_SG_ARVALID),
        .SLOT_0_AXI_awaddr(axi_dma_0_M_AXI_SG_AWADDR),
        .SLOT_0_AXI_awcache(axi_dma_0_M_AXI_SG_AWCACHE),
        .SLOT_0_AXI_awlen(axi_dma_0_M_AXI_SG_AWLEN),
        .SLOT_0_AXI_awprot(axi_dma_0_M_AXI_SG_AWPROT),
        .SLOT_0_AXI_awready(axi_dma_0_M_AXI_SG_AWREADY),
        .SLOT_0_AXI_awsize(axi_dma_0_M_AXI_SG_AWSIZE),
        .SLOT_0_AXI_awvalid(axi_dma_0_M_AXI_SG_AWVALID),
        .SLOT_0_AXI_bready(axi_dma_0_M_AXI_SG_BREADY),
        .SLOT_0_AXI_bresp(axi_dma_0_M_AXI_SG_BRESP),
        .SLOT_0_AXI_bvalid(axi_dma_0_M_AXI_SG_BVALID),
        .SLOT_0_AXI_rdata(axi_dma_0_M_AXI_SG_RDATA),
        .SLOT_0_AXI_rlast(axi_dma_0_M_AXI_SG_RLAST),
        .SLOT_0_AXI_rready(axi_dma_0_M_AXI_SG_RREADY),
        .SLOT_0_AXI_rresp(axi_dma_0_M_AXI_SG_RRESP),
        .SLOT_0_AXI_rvalid(axi_dma_0_M_AXI_SG_RVALID),
        .SLOT_0_AXI_wdata(axi_dma_0_M_AXI_SG_WDATA),
        .SLOT_0_AXI_wlast(axi_dma_0_M_AXI_SG_WLAST),
        .SLOT_0_AXI_wready(axi_dma_0_M_AXI_SG_WREADY),
        .SLOT_0_AXI_wstrb(axi_dma_0_M_AXI_SG_WSTRB),
        .SLOT_0_AXI_wvalid(axi_dma_0_M_AXI_SG_WVALID),
        .SLOT_1_AXIS_tdata(m1_axis_bridge_0_M_AXIS1_TDATA),
        .SLOT_1_AXIS_tkeep(m1_axis_bridge_0_M_AXIS1_TKEEP),
        .SLOT_1_AXIS_tlast(m1_axis_bridge_0_M_AXIS1_TLAST),
        .SLOT_1_AXIS_tready(m1_axis_bridge_0_M_AXIS1_TREADY),
        .SLOT_1_AXIS_tvalid(m1_axis_bridge_0_M_AXIS1_TVALID),
        .clk(CLK_50M_0_1),
        .resetn(1'b1));
endmodule
