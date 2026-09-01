`timescale 1ns / 1ps
/*
 * adc_burst_capture_2ch.v
 * Double-buffered capture for two AD9268 CMOS parallel channels.
 *
 * Added in this version:
 *   - Raw peak-to-peak value for ADC A/B.
 *   - 16-point moving-average filtered peak-to-peak value for ADC A/B.
 *
 * Notes:
 *   1) The BRAM still stores the original raw ADC samples.
 *   2) adc_x_raw_pp_sys is max(raw) - min(raw), in ADC code units.
 *   3) adc_x_filt_pp_sys is max(avg16) - min(avg16), also scaled back to ADC code units
 *      by shifting the moving-sum peak-to-peak value right by 4.
 *   4) Filtered peak-to-peak ignores the first 15 samples because the 16-point
 *      moving-average window is not full yet.
 */
module adc_burst_capture_2ch #(
    parameter integer SAMPLE_COUNT = 3125,
    parameter integer ADDR_WIDTH   = 12
)(
    input  wire                  sys_clk,
    input  wire                  sys_rst_n,
    input  wire                  start_sys,
    input  wire                  wr_bank_sys,
    input  wire                  rd_bank_sys,

    input  wire                  adc_dcoa,
    input  wire                  adc_dcob,
    input  wire [15:0]           adc_ina,
    input  wire [15:0]           adc_inb,

    input  wire                  rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output wire [15:0]           rd_data_a,
    output wire [15:0]           rd_data_b,
    output wire [31:0]           rd_data_pair,

    output reg  [31:0]           adc_a_raw_pp_sys,
    output reg  [31:0]           adc_b_raw_pp_sys,
    output reg  [31:0]           adc_a_filt_pp_sys,
    output reg  [31:0]           adc_b_filt_pp_sys,

    output reg                   adc_done_sys_pulse,
    output reg                   adc_done_sys_level,
    output reg                   adc_waiting_sys
);

    localparam integer FILT_LEN  = 16;
    localparam integer FILT_SHFT = 4;

    wire start_adc_a;
    wire start_adc_b;

    cdc_pulse_sync u_start_to_a (
        .src_clk   (sys_clk),
        .src_rst_n (sys_rst_n),
        .src_pulse (start_sys),
        .dst_clk   (adc_dcoa),
        .dst_rst_n (sys_rst_n),
        .dst_pulse (start_adc_a)
    );

    cdc_pulse_sync u_start_to_b (
        .src_clk   (sys_clk),
        .src_rst_n (sys_rst_n),
        .src_pulse (start_sys),
        .dst_clk   (adc_dcob),
        .dst_rst_n (sys_rst_n),
        .dst_pulse (start_adc_b)
    );

    // wr_bank_sys is stable long before start_sys. Synchronize it into each ADC DCO domain.
    reg wr_bank_a_s1, wr_bank_a_s2;
    reg wr_bank_b_s1, wr_bank_b_s2;
    always @(posedge adc_dcoa or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            wr_bank_a_s1 <= 1'b0;
            wr_bank_a_s2 <= 1'b0;
        end else begin
            wr_bank_a_s1 <= wr_bank_sys;
            wr_bank_a_s2 <= wr_bank_a_s1;
        end
    end
    always @(posedge adc_dcob or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            wr_bank_b_s1 <= 1'b0;
            wr_bank_b_s2 <= 1'b0;
        end else begin
            wr_bank_b_s1 <= wr_bank_sys;
            wr_bank_b_s2 <= wr_bank_b_s1;
        end
    end

    function signed [15:0] max_s16;
        input signed [15:0] a;
        input signed [15:0] b;
        begin
            max_s16 = (a > b) ? a : b;
        end
    endfunction

    function signed [15:0] min_s16;
        input signed [15:0] a;
        input signed [15:0] b;
        begin
            min_s16 = (a < b) ? a : b;
        end
    endfunction

    function [16:0] diff_s16;
        input signed [15:0] hi;
        input signed [15:0] lo;
        reg signed [16:0] hi17;
        reg signed [16:0] lo17;
        reg signed [16:0] d17;
        begin
            hi17 = {hi[15], hi};
            lo17 = {lo[15], lo};
            d17  = hi17 - lo17;
            diff_s16 = d17[16:0];
        end
    endfunction

    function signed [20:0] max_s21;
        input signed [20:0] a;
        input signed [20:0] b;
        begin
            max_s21 = (a > b) ? a : b;
        end
    endfunction

    function signed [20:0] min_s21;
        input signed [20:0] a;
        input signed [20:0] b;
        begin
            min_s21 = (a < b) ? a : b;
        end
    endfunction

    function [21:0] diff_s21;
        input signed [20:0] hi;
        input signed [20:0] lo;
        reg signed [21:0] hi22;
        reg signed [21:0] lo22;
        reg signed [21:0] d22;
        begin
            hi22 = {hi[20], hi};
            lo22 = {lo[20], lo};
            d22  = hi22 - lo22;
            diff_s21 = d22[21:0];
        end
    endfunction

    // -------------------------------------------------------------------------
    // ADC A capture + peak-to-peak estimator
    // -------------------------------------------------------------------------
    reg                  active_a;
    reg [ADDR_WIDTH-1:0] wr_addr_a;
    reg                  bank_a;
    reg                  done_toggle_a;

    wire signed [15:0] adc_ina_s = $signed(adc_ina);

    reg signed [15:0] raw_min_a;
    reg signed [15:0] raw_max_a;
    reg [31:0]        raw_pp_a_adc;

    reg signed [15:0] filt_shift_a [0:FILT_LEN-1];
    reg signed [20:0] filt_sum_a;
    reg signed [20:0] filt_min_a;
    reg signed [20:0] filt_max_a;
    reg [31:0]        filt_pp_a_adc;

    wire signed [15:0] filt_oldest_sample_a = filt_shift_a[FILT_LEN-1];
    wire signed [20:0] adc_ina_ext     = {{5{adc_ina_s[15]}}, adc_ina_s};
    wire signed [20:0] filt_oldest_a   = {{5{filt_oldest_sample_a[15]}}, filt_oldest_sample_a};
    wire signed [20:0] filt_sum_next_a = filt_sum_a + adc_ina_ext - filt_oldest_a;
    wire               filt_valid_a    = active_a && (wr_addr_a >= (FILT_LEN-1));

    integer ia;
    always @(posedge adc_dcoa or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            active_a      <= 1'b0;
            wr_addr_a     <= {ADDR_WIDTH{1'b0}};
            bank_a        <= 1'b0;
            done_toggle_a <= 1'b0;
            raw_min_a     <= 16'sd0;
            raw_max_a     <= 16'sd0;
            raw_pp_a_adc  <= 32'd0;
            filt_sum_a    <= 21'sd0;
            filt_min_a    <= 21'sd0;
            filt_max_a    <= 21'sd0;
            filt_pp_a_adc <= 32'd0;
            for(ia = 0; ia < FILT_LEN; ia = ia + 1)
                filt_shift_a[ia] <= 16'sd0;
        end else begin
            if(start_adc_a && !active_a) begin
                active_a      <= 1'b1;
                wr_addr_a     <= {ADDR_WIDTH{1'b0}};
                bank_a        <= wr_bank_a_s2;
                raw_min_a     <= 16'sd0;
                raw_max_a     <= 16'sd0;
                raw_pp_a_adc  <= 32'd0;
                filt_sum_a    <= 21'sd0;
                filt_min_a    <= 21'sd0;
                filt_max_a    <= 21'sd0;
                filt_pp_a_adc <= 32'd0;
                for(ia = 0; ia < FILT_LEN; ia = ia + 1)
                    filt_shift_a[ia] <= 16'sd0;
            end else if(active_a) begin
                // 16-point moving sum: shift in the current raw sample.
                filt_shift_a[0] <= adc_ina_s;
                for(ia = 1; ia < FILT_LEN; ia = ia + 1)
                    filt_shift_a[ia] <= filt_shift_a[ia-1];
                filt_sum_a <= filt_sum_next_a;

                // Raw max/min over all samples actually written to BRAM.
                if(wr_addr_a == {ADDR_WIDTH{1'b0}}) begin
                    raw_min_a <= adc_ina_s;
                    raw_max_a <= adc_ina_s;
                end else begin
                    if(adc_ina_s < raw_min_a)
                        raw_min_a <= adc_ina_s;
                    if(adc_ina_s > raw_max_a)
                        raw_max_a <= adc_ina_s;
                end

                // Filtered max/min after the 16-sample window becomes full.
                if(filt_valid_a) begin
                    if(wr_addr_a == (FILT_LEN-1)) begin
                        filt_min_a <= filt_sum_next_a;
                        filt_max_a <= filt_sum_next_a;
                    end else begin
                        if(filt_sum_next_a < filt_min_a)
                            filt_min_a <= filt_sum_next_a;
                        if(filt_sum_next_a > filt_max_a)
                            filt_max_a <= filt_sum_next_a;
                    end
                end

                if(wr_addr_a == SAMPLE_COUNT - 1) begin
                    raw_pp_a_adc <= {15'd0, diff_s16((wr_addr_a == {ADDR_WIDTH{1'b0}}) ? adc_ina_s : max_s16(adc_ina_s, raw_max_a),
                                                     (wr_addr_a == {ADDR_WIDTH{1'b0}}) ? adc_ina_s : min_s16(adc_ina_s, raw_min_a))};
                    if(filt_valid_a)
                        filt_pp_a_adc <= {10'd0, (diff_s21(max_s21(filt_sum_next_a, filt_max_a),
                                                            min_s21(filt_sum_next_a, filt_min_a)) >> FILT_SHFT)};
                    else
                        filt_pp_a_adc <= 32'd0;

                    active_a      <= 1'b0;
                    done_toggle_a <= ~done_toggle_a;
                end else begin
                    wr_addr_a <= wr_addr_a + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // ADC B capture + peak-to-peak estimator
    // -------------------------------------------------------------------------
    reg                  active_b;
    reg [ADDR_WIDTH-1:0] wr_addr_b;
    reg                  bank_b;
    reg                  done_toggle_b;

    wire signed [15:0] adc_inb_s = $signed(adc_inb);

    reg signed [15:0] raw_min_b;
    reg signed [15:0] raw_max_b;
    reg [31:0]        raw_pp_b_adc;

    reg signed [15:0] filt_shift_b [0:FILT_LEN-1];
    reg signed [20:0] filt_sum_b;
    reg signed [20:0] filt_min_b;
    reg signed [20:0] filt_max_b;
    reg [31:0]        filt_pp_b_adc;

    wire signed [15:0] filt_oldest_sample_b = filt_shift_b[FILT_LEN-1];
    wire signed [20:0] adc_inb_ext     = {{5{adc_inb_s[15]}}, adc_inb_s};
    wire signed [20:0] filt_oldest_b   = {{5{filt_oldest_sample_b[15]}}, filt_oldest_sample_b};
    wire signed [20:0] filt_sum_next_b = filt_sum_b + adc_inb_ext - filt_oldest_b;
    wire               filt_valid_b    = active_b && (wr_addr_b >= (FILT_LEN-1));

    integer ib;
    always @(posedge adc_dcob or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            active_b      <= 1'b0;
            wr_addr_b     <= {ADDR_WIDTH{1'b0}};
            bank_b        <= 1'b0;
            done_toggle_b <= 1'b0;
            raw_min_b     <= 16'sd0;
            raw_max_b     <= 16'sd0;
            raw_pp_b_adc  <= 32'd0;
            filt_sum_b    <= 21'sd0;
            filt_min_b    <= 21'sd0;
            filt_max_b    <= 21'sd0;
            filt_pp_b_adc <= 32'd0;
            for(ib = 0; ib < FILT_LEN; ib = ib + 1)
                filt_shift_b[ib] <= 16'sd0;
        end else begin
            if(start_adc_b && !active_b) begin
                active_b      <= 1'b1;
                wr_addr_b     <= {ADDR_WIDTH{1'b0}};
                bank_b        <= wr_bank_b_s2;
                raw_min_b     <= 16'sd0;
                raw_max_b     <= 16'sd0;
                raw_pp_b_adc  <= 32'd0;
                filt_sum_b    <= 21'sd0;
                filt_min_b    <= 21'sd0;
                filt_max_b    <= 21'sd0;
                filt_pp_b_adc <= 32'd0;
                for(ib = 0; ib < FILT_LEN; ib = ib + 1)
                    filt_shift_b[ib] <= 16'sd0;
            end else if(active_b) begin
                filt_shift_b[0] <= adc_inb_s;
                for(ib = 1; ib < FILT_LEN; ib = ib + 1)
                    filt_shift_b[ib] <= filt_shift_b[ib-1];
                filt_sum_b <= filt_sum_next_b;

                if(wr_addr_b == {ADDR_WIDTH{1'b0}}) begin
                    raw_min_b <= adc_inb_s;
                    raw_max_b <= adc_inb_s;
                end else begin
                    if(adc_inb_s < raw_min_b)
                        raw_min_b <= adc_inb_s;
                    if(adc_inb_s > raw_max_b)
                        raw_max_b <= adc_inb_s;
                end

                if(filt_valid_b) begin
                    if(wr_addr_b == (FILT_LEN-1)) begin
                        filt_min_b <= filt_sum_next_b;
                        filt_max_b <= filt_sum_next_b;
                    end else begin
                        if(filt_sum_next_b < filt_min_b)
                            filt_min_b <= filt_sum_next_b;
                        if(filt_sum_next_b > filt_max_b)
                            filt_max_b <= filt_sum_next_b;
                    end
                end

                if(wr_addr_b == SAMPLE_COUNT - 1) begin
                    raw_pp_b_adc <= {15'd0, diff_s16((wr_addr_b == {ADDR_WIDTH{1'b0}}) ? adc_inb_s : max_s16(adc_inb_s, raw_max_b),
                                                     (wr_addr_b == {ADDR_WIDTH{1'b0}}) ? adc_inb_s : min_s16(adc_inb_s, raw_min_b))};
                    if(filt_valid_b)
                        filt_pp_b_adc <= {10'd0, (diff_s21(max_s21(filt_sum_next_b, filt_max_b),
                                                            min_s21(filt_sum_next_b, filt_min_b)) >> FILT_SHFT)};
                    else
                        filt_pp_b_adc <= 32'd0;

                    active_b      <= 1'b0;
                    done_toggle_b <= ~done_toggle_b;
                end else begin
                    wr_addr_b <= wr_addr_b + 1'b1;
                end
            end
        end
    end

    wire [15:0] rd_a_bank0;
    wire [15:0] rd_a_bank1;
    wire [15:0] rd_b_bank0;
    wire [15:0] rd_b_bank1;

    sdp_bram #(
        .DATA_WIDTH (16),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_bram_a_bank0 (
        .wr_clk  (adc_dcoa),
        .wr_en   (active_a && (bank_a == 1'b0)),
        .wr_addr (wr_addr_a),
        .wr_data (adc_ina),
        .rd_clk  (sys_clk),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_a_bank0)
    );

    sdp_bram #(
        .DATA_WIDTH (16),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_bram_a_bank1 (
        .wr_clk  (adc_dcoa),
        .wr_en   (active_a && (bank_a == 1'b1)),
        .wr_addr (wr_addr_a),
        .wr_data (adc_ina),
        .rd_clk  (sys_clk),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_a_bank1)
    );

    sdp_bram #(
        .DATA_WIDTH (16),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_bram_b_bank0 (
        .wr_clk  (adc_dcob),
        .wr_en   (active_b && (bank_b == 1'b0)),
        .wr_addr (wr_addr_b),
        .wr_data (adc_inb),
        .rd_clk  (sys_clk),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_b_bank0)
    );

    sdp_bram #(
        .DATA_WIDTH (16),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_bram_b_bank1 (
        .wr_clk  (adc_dcob),
        .wr_en   (active_b && (bank_b == 1'b1)),
        .wr_addr (wr_addr_b),
        .wr_data (adc_inb),
        .rd_clk  (sys_clk),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_b_bank1)
    );

    assign rd_data_a    = rd_bank_sys ? rd_a_bank1 : rd_a_bank0;
    assign rd_data_b    = rd_bank_sys ? rd_b_bank1 : rd_b_bank0;
    assign rd_data_pair = {rd_data_b, rd_data_a};

    reg done_a_sync1;
    reg done_a_sync2;
    reg done_a_sync3;
    reg done_b_sync1;
    reg done_b_sync2;
    reg done_b_sync3;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            done_a_sync1 <= 1'b0;
            done_a_sync2 <= 1'b0;
            done_a_sync3 <= 1'b0;
            done_b_sync1 <= 1'b0;
            done_b_sync2 <= 1'b0;
            done_b_sync3 <= 1'b0;
        end else begin
            done_a_sync1 <= done_toggle_a;
            done_a_sync2 <= done_a_sync1;
            done_a_sync3 <= done_a_sync2;
            done_b_sync1 <= done_toggle_b;
            done_b_sync2 <= done_b_sync1;
            done_b_sync3 <= done_b_sync2;
        end
    end

    wire done_a_pulse_sys = done_a_sync2 ^ done_a_sync3;
    wire done_b_pulse_sys = done_b_sync2 ^ done_b_sync3;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            adc_a_raw_pp_sys  <= 32'd0;
            adc_b_raw_pp_sys  <= 32'd0;
            adc_a_filt_pp_sys <= 32'd0;
            adc_b_filt_pp_sys <= 32'd0;
        end else begin
            if(done_a_pulse_sys) begin
                adc_a_raw_pp_sys  <= raw_pp_a_adc;
                adc_a_filt_pp_sys <= filt_pp_a_adc;
            end
            if(done_b_pulse_sys) begin
                adc_b_raw_pp_sys  <= raw_pp_b_adc;
                adc_b_filt_pp_sys <= filt_pp_b_adc;
            end
        end
    end

    reg done_a_seen;
    reg done_b_seen;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if(!sys_rst_n) begin
            done_a_seen          <= 1'b0;
            done_b_seen          <= 1'b0;
            adc_done_sys_pulse   <= 1'b0;
            adc_done_sys_level   <= 1'b0;
            adc_waiting_sys      <= 1'b0;
        end else begin
            adc_done_sys_pulse <= 1'b0;

            if(start_sys && !adc_waiting_sys) begin
                done_a_seen        <= 1'b0;
                done_b_seen        <= 1'b0;
                adc_done_sys_level <= 1'b0;
                adc_waiting_sys    <= 1'b1;
            end else if(adc_waiting_sys) begin
                if(done_a_pulse_sys)
                    done_a_seen <= 1'b1;
                if(done_b_pulse_sys)
                    done_b_seen <= 1'b1;

                if((done_a_seen || done_a_pulse_sys) && (done_b_seen || done_b_pulse_sys)) begin
                    adc_done_sys_pulse <= 1'b1;
                    adc_done_sys_level <= 1'b1;
                    adc_waiting_sys    <= 1'b0;
                end
            end
        end
    end

endmodule
