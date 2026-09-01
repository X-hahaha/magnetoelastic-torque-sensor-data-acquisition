//Copyright 1986-2018 Xilinx, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2018.3 (win64) Build 2405991 Thu Dec  6 23:38:27 MST 2018
//Date        : Sat Aug  8 10:26:58 2026
//Host        : Yy running 64-bit major release  (build 9200)
//Command     : generate_target ps_system_wrapper.bd
//Design      : ps_system_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module ps_system_wrapper
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
  output ADC_CLK;
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
  input CLK_50M;
  inout [14:0]DDR_addr;
  inout [2:0]DDR_ba;
  inout DDR_cas_n;
  inout DDR_ck_n;
  inout DDR_ck_p;
  inout DDR_cke;
  inout DDR_cs_n;
  inout [3:0]DDR_dm;
  inout [31:0]DDR_dq;
  inout [3:0]DDR_dqs_n;
  inout [3:0]DDR_dqs_p;
  inout DDR_odt;
  inout DDR_ras_n;
  inout DDR_reset_n;
  inout DDR_we_n;
  inout FIXED_IO_ddr_vrn;
  inout FIXED_IO_ddr_vrp;
  inout [53:0]FIXED_IO_mio;
  inout FIXED_IO_ps_clk;
  inout FIXED_IO_ps_porb;
  inout FIXED_IO_ps_srstb;
  input RST_N;
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

  wire ADC_CLK;
  wire ADC_CSB;
  wire ADC_DCOA;
  wire ADC_DCOB;
  wire [15:0]ADC_INA;
  wire [15:0]ADC_INB;
  wire ADC_OEB;
  wire ADC_ORA;
  wire ADC_ORB;
  wire ADC_PDWN;
  wire ADC_SCLK;
  wire ADC_SDIO;
  wire CLK_50M;
  wire [14:0]DDR_addr;
  wire [2:0]DDR_ba;
  wire DDR_cas_n;
  wire DDR_ck_n;
  wire DDR_ck_p;
  wire DDR_cke;
  wire DDR_cs_n;
  wire [3:0]DDR_dm;
  wire [31:0]DDR_dq;
  wire [3:0]DDR_dqs_n;
  wire [3:0]DDR_dqs_p;
  wire DDR_odt;
  wire DDR_ras_n;
  wire DDR_reset_n;
  wire DDR_we_n;
  wire FIXED_IO_ddr_vrn;
  wire FIXED_IO_ddr_vrp;
  wire [53:0]FIXED_IO_mio;
  wire FIXED_IO_ps_clk;
  wire FIXED_IO_ps_porb;
  wire FIXED_IO_ps_srstb;
  wire RST_N;
  wire RXD_LAYSER1;
  wire RXD_LAYSER2;
  wire RXD_LAYSER3;
  wire RXD_LAYSER4;
  wire RXD_LAYSER5;
  wire RXD_TEMPERATURE;
  wire TXD_LAYSER1;
  wire TXD_LAYSER2;
  wire TXD_LAYSER3;
  wire TXD_LAYSER4;
  wire TXD_LAYSER5;
  wire TXD_TEMPERATURE;

  ps_system ps_system_i
       (.ADC_CLK(ADC_CLK),
        .ADC_CSB(ADC_CSB),
        .ADC_DCOA(ADC_DCOA),
        .ADC_DCOB(ADC_DCOB),
        .ADC_INA(ADC_INA),
        .ADC_INB(ADC_INB),
        .ADC_OEB(ADC_OEB),
        .ADC_ORA(ADC_ORA),
        .ADC_ORB(ADC_ORB),
        .ADC_PDWN(ADC_PDWN),
        .ADC_SCLK(ADC_SCLK),
        .ADC_SDIO(ADC_SDIO),
        .CLK_50M(CLK_50M),
        .DDR_addr(DDR_addr),
        .DDR_ba(DDR_ba),
        .DDR_cas_n(DDR_cas_n),
        .DDR_ck_n(DDR_ck_n),
        .DDR_ck_p(DDR_ck_p),
        .DDR_cke(DDR_cke),
        .DDR_cs_n(DDR_cs_n),
        .DDR_dm(DDR_dm),
        .DDR_dq(DDR_dq),
        .DDR_dqs_n(DDR_dqs_n),
        .DDR_dqs_p(DDR_dqs_p),
        .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n),
        .DDR_reset_n(DDR_reset_n),
        .DDR_we_n(DDR_we_n),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio),
        .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb(FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
        .RST_N(RST_N),
        .RXD_LAYSER1(RXD_LAYSER1),
        .RXD_LAYSER2(RXD_LAYSER2),
        .RXD_LAYSER3(RXD_LAYSER3),
        .RXD_LAYSER4(RXD_LAYSER4),
        .RXD_LAYSER5(RXD_LAYSER5),
        .RXD_TEMPERATURE(RXD_TEMPERATURE),
        .TXD_LAYSER1(TXD_LAYSER1),
        .TXD_LAYSER2(TXD_LAYSER2),
        .TXD_LAYSER3(TXD_LAYSER3),
        .TXD_LAYSER4(TXD_LAYSER4),
        .TXD_LAYSER5(TXD_LAYSER5),
        .TXD_TEMPERATURE(TXD_TEMPERATURE));
endmodule
