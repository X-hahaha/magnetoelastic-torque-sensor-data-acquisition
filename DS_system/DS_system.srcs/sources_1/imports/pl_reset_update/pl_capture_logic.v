`timescale 1ns / 1ps
/*
 * PL top for host-triggered long-frame acquisition.
 *
 * The BD-facing ports are intentionally kept compatible with the existing
 * DS_system_02ms block design.  The former AXI-Lite waveform-read pulse
 * ps_adc_sample_rd_en is now used as a one-cycle capture_start pulse from PS.
 *
 * Capture flow:
 *   PS UDP command -> AXI-Lite write 0x38 -> capture_start_pulse
 *   ADC DCO-domain streaming capture -> AXIS -> AXI DMA S2MM -> DDR
 *   header -> full raw waveform -> sensor timeline -> final summary -> footer/TLAST
 */
module pl_capture_logic (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK_50M CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET RST_N, FREQ_HZ 50000000" *)
    input           CLK_50M,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 RST_N RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input           RST_N,

    input           ps_pl_reset_hold,

    input  [15:0]   ADC_INA,
    input  [15:0]   ADC_INB,
    output          ADC_CLK,

    input           ADC_DCOA,
    input           ADC_DCOB,
    input           ADC_ORA,
    input           ADC_ORB,

    output          ADC_PDWN,
    output          ADC_OEB,
    output          ADC_CSB,
    output          ADC_SCLK,
    inout           ADC_SDIO,

    input           TXD_TEMPERATURE,
    output          RXD_TEMPERATURE,

    input           TXD_LAYSER1,
    output          RXD_LAYSER1,
    input           TXD_LAYSER2,
    output          RXD_LAYSER2,
    input           TXD_LAYSER3,
    output          RXD_LAYSER3,
    input           TXD_LAYSER4,
    output          RXD_LAYSER4,
    input           TXD_LAYSER5,
    output          RXD_LAYSER5,
    output wire [31:0] ps_frame_id,
    output wire signed [31:0] ps_laser1_um,
    output wire signed [31:0] ps_laser2_um,
    output wire signed [31:0] ps_laser3_um,
    output wire signed [31:0] ps_laser4_um,
    output wire signed [31:0] ps_laser5_um,
    output wire signed [15:0] ps_temperature_x10,
    output wire [31:0] ps_adc_a_raw_pp,
    output wire [31:0] ps_adc_b_raw_pp,
    output wire [31:0] ps_adc_a_filt_pp,
    output wire [31:0] ps_adc_b_filt_pp,
    output wire [5:0] ps_sensor_valid_seen,
    output wire [5:0] ps_sensor_crc_error,
    output wire [5:0] ps_sensor_timeout_error,
    output wire [5:0] ps_sensor_frame_error,

    // Reused as capture control/status in the long-frame design.
    input  wire        ps_adc_sample_rd_en,
    input  wire [11:0] ps_adc_sample_rd_addr,
    output wire [31:0] ps_adc_sample_rd_data,

    // Runtime waveform length from laser_axi_regs (samples per channel).
    input  wire [31:0] sample_count_cfg,

    (* X_INTERFACE_IGNORE = "TRUE" *) (* mark_debug = "true" *) output wire [31:0] M_AXIS_FRAME_TDATA,
    (* X_INTERFACE_IGNORE = "TRUE" *) (* mark_debug = "true" *) output wire [3:0]  M_AXIS_FRAME_TKEEP,
    (* X_INTERFACE_IGNORE = "TRUE" *) (* mark_debug = "true" *) output wire        M_AXIS_FRAME_TVALID,
    (* X_INTERFACE_IGNORE = "TRUE" *) (* mark_debug = "true" *) input  wire        M_AXIS_FRAME_TREADY,
    (* X_INTERFACE_IGNORE = "TRUE" *) (* mark_debug = "true" *) output wire        M_AXIS_FRAME_TLAST,

    output wire [31:0] ps_axis_frame_id,
    output wire [31:0] ps_axis_overrun_count,
    output wire [31:0] ps_axis_backpressure_count
);

    localparam integer SYS_CLK_FREQ_HZ      = 50_000_000;
    // Waveform length is runtime-configurable via sample_count_cfg (AXI-Lite
    // register in laser_axi_regs, default 4687500 = 0.3 s); the frame packer
    // latches it at capture start. Manual mode = default, auto mode = short.
    localparam integer SAMPLE_RATE_HZ       = 15625000;
    localparam integer FRAME_HEADER_BYTES   = 256;
    localparam integer SUMMARY_BYTES        = 128;
    localparam integer FOOTER_BYTES         = 40;
    localparam integer FIFO_ADDR_WIDTH      = 10;
    localparam integer SENSOR_TIMELINE_DEPTH = 4096;

    wire clk_125m;
    wire clk_15_625m_debug;
    wire pll_locked;
    wire sys_rst_n = RST_N & pll_locked & (~ps_pl_reset_hold);

    clk_gen_50m_to_125m u_clk_gen (
        .clk_50m       (CLK_50M),
        .resetn        (RST_N),
        .clk_125m      (clk_125m),
        .clk_15_625m   (clk_15_625m_debug),
        .locked        (pll_locked)
    );

    assign ADC_CLK  = clk_125m;
    assign ADC_PDWN = 1'b0;
    assign ADC_OEB  = 1'b0;

    wire clk_1p25m;
    clk_div_125m_to_1p25m u_clk_div_spi (
        .clk_125m  (clk_125m),
        .rst_n     (sys_rst_n),
        .clk_1p25m (clk_1p25m)
    );

    wire adc_config_done_raw;
    adc9268_config u_adc9268_config (
        .clk_1p25m  (clk_1p25m),
        .rst_n      (sys_rst_n),
        .adc_csb    (ADC_CSB),
        .adc_sclk   (ADC_SCLK),
        .adc_sdio   (ADC_SDIO),
        .config_done(adc_config_done_raw)
    );

    reg adc_config_done_s1;
    reg adc_config_done_s2;
    always @(posedge CLK_50M or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            adc_config_done_s1 <= 1'b0;
            adc_config_done_s2 <= 1'b0;
        end else begin
            adc_config_done_s1 <= adc_config_done_raw;
            adc_config_done_s2 <= adc_config_done_s1;
        end
    end
    wire adc_config_done = adc_config_done_s2;

    wire signed [31:0] laser1_distance_um;
    wire signed [31:0] laser2_distance_um;
    wire signed [31:0] laser3_distance_um;
    wire signed [31:0] laser4_distance_um;
    wire signed [31:0] laser5_distance_um;
    wire signed [15:0] temperature_x10;
    wire [5:0] sensor_valid_pulse;
    wire [5:0] sensor_valid_seen;
    wire [5:0] sensor_busy;
    wire [5:0] sensor_crc_error;
    wire [5:0] sensor_timeout_error;
    wire [5:0] sensor_frame_error;

    rs485_sensors_reader #(
        .CLK_FREQ_HZ     (SYS_CLK_FREQ_HZ),
        .LASER_INIT_BAUD (468800),
        .LASER_BAUD_RATE (468800),
        .TEMP_BAUD_RATE  (9600),
        .SENSOR_ADDR     (8'h01)
    ) u_rs485_sensors_reader (
        .clk                  (CLK_50M),
        .rst_n                (sys_rst_n),
        .TXD_LAYSER1          (TXD_LAYSER1),
        .RXD_LAYSER1          (RXD_LAYSER1),
        .TXD_LAYSER2          (TXD_LAYSER2),
        .RXD_LAYSER2          (RXD_LAYSER2),
        .TXD_LAYSER3          (TXD_LAYSER3),
        .RXD_LAYSER3          (RXD_LAYSER3),
        .TXD_LAYSER4          (TXD_LAYSER4),
        .RXD_LAYSER4          (RXD_LAYSER4),
        .TXD_LAYSER5          (TXD_LAYSER5),
        .RXD_LAYSER5          (RXD_LAYSER5),
        .TXD_TEMPERATURE      (TXD_TEMPERATURE),
        .RXD_TEMPERATURE      (RXD_TEMPERATURE),
        .laser1_distance_um   (laser1_distance_um),
        .laser2_distance_um   (laser2_distance_um),
        .laser3_distance_um   (laser3_distance_um),
        .laser4_distance_um   (laser4_distance_um),
        .laser5_distance_um   (laser5_distance_um),
        .temperature_x10      (temperature_x10),
        .valid_pulse          (sensor_valid_pulse),
        .valid_seen           (sensor_valid_seen),
        .busy                 (sensor_busy),
        .crc_error            (sensor_crc_error),
        .timeout_error        (sensor_timeout_error),
        .frame_error          (sensor_frame_error)
    );

    wire m2_axis_active;
    wire [31:0] m2_axis_completed_count;
    wire [31:0] m2_fifo_overflow_count;
    wire [31:0] m2_debug_status;
    wire [31:0] adc_a_raw_pp;
    wire [31:0] adc_b_raw_pp;
    wire [31:0] adc_a_filt_pp;
    wire [31:0] adc_b_filt_pp;

    fr16_adc_frame_axis #(
        .FRAME_HEADER_BYTES (FRAME_HEADER_BYTES),
        .SAMPLE_RATE_HZ     (SAMPLE_RATE_HZ),
        .SUMMARY_BYTES      (SUMMARY_BYTES),
        .FOOTER_BYTES       (FOOTER_BYTES),
        .FIFO_ADDR_WIDTH    (FIFO_ADDR_WIDTH),
        .SENSOR_TIMELINE_DEPTH (SENSOR_TIMELINE_DEPTH)
    ) u_fr16_adc_frame_axis (
        .clk                       (CLK_50M),
        .rst_n                     (sys_rst_n),
        .enable                    (adc_config_done),
        .capture_start_pulse       (ps_adc_sample_rd_en),
        .sample_count_cfg          (sample_count_cfg),
        .adc_dco                   (ADC_DCOA),
        .adc_ina                   (ADC_INA),
        .adc_inb                   (ADC_INB),
        .adc_ora                   (ADC_ORA),
        .adc_orb                   (ADC_ORB),
        .laser1_um                 (laser1_distance_um),
        .laser2_um                 (laser2_distance_um),
        .laser3_um                 (laser3_distance_um),
        .laser4_um                 (laser4_distance_um),
        .laser5_um                 (laser5_distance_um),
        .temperature_x10           (temperature_x10),
        .sensor_valid_pulse        (sensor_valid_pulse),
        .sensor_valid_seen         (sensor_valid_seen),
        .sensor_busy               (sensor_busy),
        .sensor_crc_error          (sensor_crc_error),
        .sensor_timeout_error      (sensor_timeout_error),
        .sensor_frame_error        (sensor_frame_error),
        .m_axis_tdata              (M_AXIS_FRAME_TDATA),
        .m_axis_tkeep              (M_AXIS_FRAME_TKEEP),
        .m_axis_tvalid             (M_AXIS_FRAME_TVALID),
        .m_axis_tready             (M_AXIS_FRAME_TREADY),
        .m_axis_tlast              (M_AXIS_FRAME_TLAST),
        .active                    (m2_axis_active),
        .last_completed_frame_id   (ps_axis_frame_id),
        .frame_overrun_count       (ps_axis_overrun_count),
        .axis_backpressure_count   (ps_axis_backpressure_count),
        .fifo_overflow_count       (m2_fifo_overflow_count),
        .completed_frame_count     (m2_axis_completed_count),
        .last_adc_a_raw_pp         (adc_a_raw_pp),
        .last_adc_b_raw_pp         (adc_b_raw_pp),
        .last_adc_a_filt_pp        (adc_a_filt_pp),
        .last_adc_b_filt_pp        (adc_b_filt_pp),
        .debug_status              (m2_debug_status)
    );

    (* mark_debug = "true" *) wire ila_capture_start = ps_adc_sample_rd_en;
    (* mark_debug = "true" *) wire ila_capture_active = m2_axis_active;
    (* mark_debug = "true" *) wire ila_adc_config_done = adc_config_done;
    (* mark_debug = "true" *) wire [31:0] ila_axis_frame_id = ps_axis_frame_id;

    assign ps_frame_id             = ps_axis_frame_id;
    assign ps_laser1_um            = laser1_distance_um;
    assign ps_laser2_um            = laser2_distance_um;
    assign ps_laser3_um            = laser3_distance_um;
    assign ps_laser4_um            = laser4_distance_um;
    assign ps_laser5_um            = laser5_distance_um;
    assign ps_temperature_x10      = temperature_x10;

    assign ps_adc_a_raw_pp         = adc_a_raw_pp;
    assign ps_adc_b_raw_pp         = adc_b_raw_pp;
    assign ps_adc_a_filt_pp        = adc_a_filt_pp;
    assign ps_adc_b_filt_pp        = adc_b_filt_pp;

    assign ps_sensor_valid_seen    = sensor_valid_seen;
    assign ps_sensor_crc_error     = sensor_crc_error;
    assign ps_sensor_timeout_error = sensor_timeout_error;
    assign ps_sensor_frame_error   = sensor_frame_error;

    assign ps_adc_sample_rd_data   = m2_debug_status;

endmodule
