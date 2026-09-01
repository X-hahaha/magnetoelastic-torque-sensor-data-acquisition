`timescale 1ns / 1ps
/*
 * daq_capture_core.v
 * Main PL-side storage core with double buffering:
 *   - Background RS485 sensor data is latched at trigger time.
 *   - ADC A/B are captured for SAMPLE_COUNT points into one of two BRAM banks.
 *   - When capture completes, that bank becomes the latest completed read bank.
 *   - The next capture writes the other bank, so reads of the latest completed bank are not overwritten.
 *
 * Read interface:
 *   rd_data is valid one sys_clk after rd_en.
 *   rd_sel = 0: metadata/sensor snapshot of the latest completed bank
 *   rd_sel = 1: ADC A, lower 16 bits valid
 *   rd_sel = 2: ADC B, lower 16 bits valid
 *   rd_sel = 3: {ADC_B[15:0], ADC_A[15:0]}
 */
module daq_capture_core #(
    parameter integer SAMPLE_COUNT = 3125,
    parameter integer ADDR_WIDTH   = 12
)(
    input  wire                  sys_clk,
    input  wire                  sys_rst_n,

    input  wire                  capture_start_sys,

    input  wire [15:0]           adc_ina,
    input  wire [15:0]           adc_inb,
    input  wire                  adc_dcoa,
    input  wire                  adc_dcob,
    input  wire                  adc_ora,
    input  wire                  adc_orb,

    input  wire signed [31:0]    laser1_distance_um,
    input  wire signed [31:0]    laser2_distance_um,
    input  wire signed [31:0]    laser3_distance_um,
    input  wire signed [31:0]    laser4_distance_um,
    input  wire signed [31:0]    laser5_distance_um,
    input  wire signed [15:0]    temperature_x10,
    input  wire [5:0]            sensor_valid_seen,
    input  wire [5:0]            sensor_busy,
    input  wire [5:0]            sensor_crc_error,
    input  wire [5:0]            sensor_timeout_error,
    input  wire [5:0]            sensor_frame_error,

    input  wire                  rd_en,
    input  wire [1:0]            rd_sel,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    input  wire                  rd_bank_sys,
    output reg  [31:0]           rd_data,
    output wire [31:0]           rd_data_pair_raw,

    output wire signed [31:0]    snapshot_laser1_um,
    output wire signed [31:0]    snapshot_laser2_um,
    output wire signed [31:0]    snapshot_laser3_um,
    output wire signed [31:0]    snapshot_laser4_um,
    output wire signed [31:0]    snapshot_laser5_um,
    output wire signed [15:0]    snapshot_temperature_x10,
    output wire [5:0]            snapshot_sensor_valid_seen,
    output wire [5:0]            snapshot_sensor_busy,
    output wire [5:0]            snapshot_sensor_crc_error,
    output wire [5:0]            snapshot_sensor_timeout_error,
    output wire [5:0]            snapshot_sensor_frame_error,
    output wire [1:0]            snapshot_adc_overrange,

    output wire [31:0]           adc_a_raw_pp,
    output wire [31:0]           adc_b_raw_pp,
    output wire [31:0]           adc_a_filt_pp,
    output wire [31:0]           adc_b_filt_pp,

    output reg                   capture_busy,
    output reg                   capture_done_pulse,
    output reg                   capture_done_level,
    output reg  [31:0]           capture_id,
    output reg                   latest_bank
);

    wire start_accepted = capture_start_sys && !capture_busy;

    reg write_bank;
    reg active_write_bank;

    reg signed [31:0] snap_laser1_bank0;
    reg signed [31:0] snap_laser2_bank0;
    reg signed [31:0] snap_laser3_bank0;
    reg signed [31:0] snap_laser4_bank0;
    reg signed [31:0] snap_laser5_bank0;
    reg signed [15:0] snap_temp_bank0;
    reg [5:0]         snap_valid_bank0;
    reg [5:0]         snap_busy_bank0;
    reg [5:0]         snap_crc_bank0;
    reg [5:0]         snap_timeout_bank0;
    reg [5:0]         snap_frame_bank0;
    reg [1:0]         snap_adc_or_bank0;
    reg [31:0]        snap_capture_id_bank0;

    reg signed [31:0] snap_laser1_bank1;
    reg signed [31:0] snap_laser2_bank1;
    reg signed [31:0] snap_laser3_bank1;
    reg signed [31:0] snap_laser4_bank1;
    reg signed [31:0] snap_laser5_bank1;
    reg signed [15:0] snap_temp_bank1;
    reg [5:0]         snap_valid_bank1;
    reg [5:0]         snap_busy_bank1;
    reg [5:0]         snap_crc_bank1;
    reg [5:0]         snap_timeout_bank1;
    reg [5:0]         snap_frame_bank1;
    reg [1:0]         snap_adc_or_bank1;
    reg [31:0]        snap_capture_id_bank1;

    wire [15:0] adc_rd_data_a;
    wire [15:0] adc_rd_data_b;
    wire [31:0] adc_rd_data_pair;
    wire        adc_done_sys_pulse;
    wire        adc_done_sys_level;
    wire        adc_waiting_sys;

    adc_burst_capture_2ch #(
        .SAMPLE_COUNT (SAMPLE_COUNT),
        .ADDR_WIDTH   (ADDR_WIDTH)
    ) u_adc_burst_capture_2ch (
        .sys_clk            (sys_clk),
        .sys_rst_n          (sys_rst_n),
        .start_sys          (start_accepted),
        .wr_bank_sys        (write_bank),
        .rd_bank_sys        (rd_bank_sys),
        .adc_dcoa           (adc_dcoa),
        .adc_dcob           (adc_dcob),
        .adc_ina            (adc_ina),
        .adc_inb            (adc_inb),
        .rd_en              (rd_en),
        .rd_addr            (rd_addr),
        .rd_data_a          (adc_rd_data_a),
        .rd_data_b          (adc_rd_data_b),
        .rd_data_pair       (adc_rd_data_pair),
        .adc_a_raw_pp_sys   (adc_a_raw_pp),
        .adc_b_raw_pp_sys   (adc_b_raw_pp),
        .adc_a_filt_pp_sys  (adc_a_filt_pp),
        .adc_b_filt_pp_sys  (adc_b_filt_pp),
        .adc_done_sys_pulse (adc_done_sys_pulse),
        .adc_done_sys_level (adc_done_sys_level),
        .adc_waiting_sys    (adc_waiting_sys)
    );

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            capture_busy       <= 1'b0;
            capture_done_pulse <= 1'b0;
            capture_done_level <= 1'b0;
            capture_id         <= 32'd0;
            latest_bank        <= 1'b0;
            write_bank         <= 1'b0;
            active_write_bank  <= 1'b0;

            snap_laser1_bank0 <= 32'sd0; snap_laser2_bank0 <= 32'sd0; snap_laser3_bank0 <= 32'sd0;
            snap_laser4_bank0 <= 32'sd0; snap_laser5_bank0 <= 32'sd0; snap_temp_bank0 <= 16'sd0;
            snap_valid_bank0 <= 6'd0; snap_busy_bank0 <= 6'd0; snap_crc_bank0 <= 6'd0;
            snap_timeout_bank0 <= 6'd0; snap_frame_bank0 <= 6'd0; snap_adc_or_bank0 <= 2'd0; snap_capture_id_bank0 <= 32'd0;

            snap_laser1_bank1 <= 32'sd0; snap_laser2_bank1 <= 32'sd0; snap_laser3_bank1 <= 32'sd0;
            snap_laser4_bank1 <= 32'sd0; snap_laser5_bank1 <= 32'sd0; snap_temp_bank1 <= 16'sd0;
            snap_valid_bank1 <= 6'd0; snap_busy_bank1 <= 6'd0; snap_crc_bank1 <= 6'd0;
            snap_timeout_bank1 <= 6'd0; snap_frame_bank1 <= 6'd0; snap_adc_or_bank1 <= 2'd0; snap_capture_id_bank1 <= 32'd0;
        end else begin
            capture_done_pulse <= 1'b0;

            if(start_accepted) begin
                capture_busy       <= 1'b1;
                capture_done_level <= 1'b0;
                capture_id         <= capture_id + 1'b1;
                active_write_bank  <= write_bank;

                if(write_bank == 1'b0) begin
                    snap_laser1_bank0    <= laser1_distance_um;
                    snap_laser2_bank0    <= laser2_distance_um;
                    snap_laser3_bank0    <= laser3_distance_um;
                    snap_laser4_bank0    <= laser4_distance_um;
                    snap_laser5_bank0    <= laser5_distance_um;
                    snap_temp_bank0      <= temperature_x10;
                    snap_valid_bank0     <= sensor_valid_seen;
                    snap_busy_bank0      <= sensor_busy;
                    snap_crc_bank0       <= sensor_crc_error;
                    snap_timeout_bank0   <= sensor_timeout_error;
                    snap_frame_bank0     <= sensor_frame_error;
                    snap_adc_or_bank0    <= {adc_orb, adc_ora};
                    snap_capture_id_bank0<= capture_id + 1'b1;
                end else begin
                    snap_laser1_bank1    <= laser1_distance_um;
                    snap_laser2_bank1    <= laser2_distance_um;
                    snap_laser3_bank1    <= laser3_distance_um;
                    snap_laser4_bank1    <= laser4_distance_um;
                    snap_laser5_bank1    <= laser5_distance_um;
                    snap_temp_bank1      <= temperature_x10;
                    snap_valid_bank1     <= sensor_valid_seen;
                    snap_busy_bank1      <= sensor_busy;
                    snap_crc_bank1       <= sensor_crc_error;
                    snap_timeout_bank1   <= sensor_timeout_error;
                    snap_frame_bank1     <= sensor_frame_error;
                    snap_adc_or_bank1    <= {adc_orb, adc_ora};
                    snap_capture_id_bank1<= capture_id + 1'b1;
                end
            end else if(adc_done_sys_pulse) begin
                capture_busy       <= 1'b0;
                capture_done_pulse <= 1'b1;
                capture_done_level <= 1'b1;
                latest_bank        <= active_write_bank;
                write_bank         <= ~active_write_bank;
            end
        end
    end

    assign rd_data_pair_raw             = adc_rd_data_pair;

    assign snapshot_laser1_um           = latest_bank ? snap_laser1_bank1 : snap_laser1_bank0;
    assign snapshot_laser2_um           = latest_bank ? snap_laser2_bank1 : snap_laser2_bank0;
    assign snapshot_laser3_um           = latest_bank ? snap_laser3_bank1 : snap_laser3_bank0;
    assign snapshot_laser4_um           = latest_bank ? snap_laser4_bank1 : snap_laser4_bank0;
    assign snapshot_laser5_um           = latest_bank ? snap_laser5_bank1 : snap_laser5_bank0;
    assign snapshot_temperature_x10     = latest_bank ? snap_temp_bank1   : snap_temp_bank0;
    assign snapshot_sensor_valid_seen   = latest_bank ? snap_valid_bank1  : snap_valid_bank0;
    assign snapshot_sensor_busy         = latest_bank ? snap_busy_bank1   : snap_busy_bank0;
    assign snapshot_sensor_crc_error    = latest_bank ? snap_crc_bank1    : snap_crc_bank0;
    assign snapshot_sensor_timeout_error= latest_bank ? snap_timeout_bank1: snap_timeout_bank0;
    assign snapshot_sensor_frame_error  = latest_bank ? snap_frame_bank1  : snap_frame_bank0;
    assign snapshot_adc_overrange       = latest_bank ? snap_adc_or_bank1 : snap_adc_or_bank0;

    wire signed [31:0] snap_laser1_rd  = latest_bank ? snap_laser1_bank1 : snap_laser1_bank0;
    wire signed [31:0] snap_laser2_rd  = latest_bank ? snap_laser2_bank1 : snap_laser2_bank0;
    wire signed [31:0] snap_laser3_rd  = latest_bank ? snap_laser3_bank1 : snap_laser3_bank0;
    wire signed [31:0] snap_laser4_rd  = latest_bank ? snap_laser4_bank1 : snap_laser4_bank0;
    wire signed [31:0] snap_laser5_rd  = latest_bank ? snap_laser5_bank1 : snap_laser5_bank0;
    wire signed [15:0] snap_temp_rd    = latest_bank ? snap_temp_bank1   : snap_temp_bank0;
    wire [5:0]         snap_valid_rd   = latest_bank ? snap_valid_bank1  : snap_valid_bank0;
    wire [5:0]         snap_busy_rd    = latest_bank ? snap_busy_bank1   : snap_busy_bank0;
    wire [5:0]         snap_crc_rd     = latest_bank ? snap_crc_bank1    : snap_crc_bank0;
    wire [5:0]         snap_timeout_rd = latest_bank ? snap_timeout_bank1: snap_timeout_bank0;
    wire [5:0]         snap_frame_rd   = latest_bank ? snap_frame_bank1  : snap_frame_bank0;
    wire [1:0]         snap_adc_or_rd  = latest_bank ? snap_adc_or_bank1 : snap_adc_or_bank0;
    wire [31:0]        snap_capture_id_rd = latest_bank ? snap_capture_id_bank1 : snap_capture_id_bank0;

    reg [1:0]  rd_sel_d;
    reg [31:0] meta_rd_data_d;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            rd_sel_d       <= 2'd0;
            meta_rd_data_d <= 32'd0;
            rd_data        <= 32'd0;
        end else begin
            if(rd_en) begin
                rd_sel_d <= rd_sel;
                case(rd_addr)
                    12'd0:  meta_rd_data_d <= 32'hDA71_0002; // version 2: double buffer
                    12'd1:  meta_rd_data_d <= SAMPLE_COUNT;
                    12'd2:  meta_rd_data_d <= {23'd0, latest_bank, snap_adc_or_rd, capture_done_level, capture_busy, adc_waiting_sys, adc_done_sys_level, 2'b00};
                    12'd3:  meta_rd_data_d <= snap_capture_id_rd;
                    12'd4:  meta_rd_data_d <= {26'd0, snap_valid_rd};
                    12'd5:  meta_rd_data_d <= {14'd0, snap_frame_rd, snap_timeout_rd, snap_crc_rd};
                    12'd6:  meta_rd_data_d <= snap_laser1_rd;
                    12'd7:  meta_rd_data_d <= snap_laser2_rd;
                    12'd8:  meta_rd_data_d <= snap_laser3_rd;
                    12'd9:  meta_rd_data_d <= snap_laser4_rd;
                    12'd10: meta_rd_data_d <= snap_laser5_rd;
                    12'd11: meta_rd_data_d <= {{16{snap_temp_rd[15]}}, snap_temp_rd};
                    12'd12: meta_rd_data_d <= {26'd0, sensor_valid_seen};
                    12'd13: meta_rd_data_d <= {14'd0, sensor_frame_error, sensor_timeout_error, sensor_crc_error};
                    12'd14: meta_rd_data_d <= {26'd0, sensor_busy};
                    default: meta_rd_data_d <= 32'd0;
                endcase
            end

            case(rd_sel_d)
                2'd0: rd_data <= meta_rd_data_d;
                2'd1: rd_data <= {16'd0, adc_rd_data_a};
                2'd2: rd_data <= {16'd0, adc_rd_data_b};
                2'd3: rd_data <= adc_rd_data_pair;
                default: rd_data <= 32'd0;
            endcase
        end
    end

endmodule
