`timescale 1ns / 1ps
/*
 * clk_gen_50m_to_125m.v
 * MMCM clock generator for Zynq-7020 7-series devices.
 * Input:  50 MHz
 * Output: 125 MHz for AD9268 input clock and SPI clock divider.
 * Also outputs 15.625 MHz for optional debug only.
 */
module clk_gen_50m_to_125m(
    input  wire clk_50m,
    input  wire resetn,
    output wire clk_125m,
    output wire clk_15_625m,
    output wire locked
);

    wire clkfb;
    wire clkfb_buf;
    wire clk_125m_raw;
    wire clk_15_625m_raw;

    MMCME2_BASE #(
        .BANDWIDTH            ("OPTIMIZED"),
        .CLKIN1_PERIOD        (20.000),
        .DIVCLK_DIVIDE        (1),
        .CLKFBOUT_MULT_F      (20.000), // VCO = 50 MHz * 20 = 1000 MHz
        .CLKFBOUT_PHASE       (0.000),
        .CLKOUT0_DIVIDE_F     (8.000),  // 1000 / 8  = 125 MHz
        .CLKOUT0_PHASE        (0.000),
        .CLKOUT0_DUTY_CYCLE   (0.500),
        .CLKOUT1_DIVIDE       (64),     // 1000 / 64 = 15.625 MHz
        .CLKOUT1_PHASE        (0.000),
        .CLKOUT1_DUTY_CYCLE   (0.500),
        .CLKOUT2_DIVIDE       (1),
        .CLKOUT3_DIVIDE       (1),
        .CLKOUT4_DIVIDE       (1),
        .CLKOUT5_DIVIDE       (1),
        .CLKOUT6_DIVIDE       (1),
        .STARTUP_WAIT         ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk_50m),
        .CLKFBIN  (clkfb_buf),
        .CLKFBOUT (clkfb),
        .CLKFBOUTB(),
        .CLKOUT0  (clk_125m_raw),
        .CLKOUT0B (),
        .CLKOUT1  (clk_15_625m_raw),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (~resetn)
    );

    BUFG u_bufg_fb  (.I(clkfb),           .O(clkfb_buf));
    BUFG u_bufg_125 (.I(clk_125m_raw),    .O(clk_125m));
    BUFG u_bufg_15  (.I(clk_15_625m_raw), .O(clk_15_625m));

endmodule
