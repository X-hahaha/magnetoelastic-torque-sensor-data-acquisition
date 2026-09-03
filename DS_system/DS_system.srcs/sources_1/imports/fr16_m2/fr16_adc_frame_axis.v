`timescale 1ns / 1ps
/*
 * fr16_adc_frame_axis.v
 *
 * Host-triggered long-frame real ADC packer.
 *
 * The old M2 packer read a short BRAM capture after an automatic trigger.
 * This version streams the complete frame directly from the ADC DCO domain
 * through a small asynchronous FIFO into the existing AXI DMA S2MM path:
 *
 *   256-byte FR16 header
 *   sample_count 32-bit sample pairs, {ADC_B[15:0], ADC_A[15:0]}
 *   fixed-size sensor timeline, 40 bytes/entry
 *   128-byte final summary
 *   40-byte DONE footer with TLAST
 *
 * The waveform length is runtime-configurable through sample_count_cfg
 * (AXI-Lite register in laser_axi_regs). The value is latched when a capture
 * is accepted, so PS may only change it while no capture is active. All
 * frame-length fields in header/summary/footer follow the latched value, and
 * the PS parses the frame with the same count it programmed.
 *
 * Peak-to-peak values are computed while the waveform is captured, so the
 * summary is emitted only after the final waveform word has been accepted.
 */
module fr16_adc_frame_axis #(
    parameter integer FRAME_HEADER_BYTES = 256,
    // Legacy default / maximum waveform length; the runtime length comes from
    // the sample_count_cfg input and is latched per capture.
    parameter integer SAMPLE_COUNT       = 4687500,
    parameter integer SAMPLE_RATE_HZ     = 15625000,
    parameter integer SUMMARY_BYTES      = 128,
    parameter integer FOOTER_BYTES       = 40,
    parameter integer FIFO_ADDR_WIDTH    = 10,
    // 700 us laser polling x 5 channels over a 300 ms capture needs ~2150
    // entries; 4096 covers it with margin (and faster polling up to ~350 us).
    parameter integer SENSOR_TIMELINE_DEPTH = 4096
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     enable,
    input  wire                     capture_start_pulse,
    input  wire [31:0]              sample_count_cfg,

    input  wire                     adc_dco,
    input  wire [15:0]              adc_ina,
    input  wire [15:0]              adc_inb,
    input  wire                     adc_ora,
    input  wire                     adc_orb,

    input  wire signed [31:0]       laser1_um,
    input  wire signed [31:0]       laser2_um,
    input  wire signed [31:0]       laser3_um,
    input  wire signed [31:0]       laser4_um,
    input  wire signed [31:0]       laser5_um,
    input  wire signed [15:0]       temperature_x10,
    input  wire [5:0]               sensor_valid_pulse,
    input  wire [5:0]               sensor_valid_seen,
    input  wire [5:0]               sensor_busy,
    input  wire [5:0]               sensor_crc_error,
    input  wire [5:0]               sensor_timeout_error,
    input  wire [5:0]               sensor_frame_error,

    output reg  [31:0]              m_axis_tdata,
    output wire [3:0]               m_axis_tkeep,
    output reg                      m_axis_tvalid,
    input  wire                     m_axis_tready,
    output reg                      m_axis_tlast,

    output wire                     active,
    output reg  [31:0]              last_completed_frame_id,
    output reg  [31:0]              frame_overrun_count,
    output reg  [31:0]              axis_backpressure_count,
    output reg  [31:0]              fifo_overflow_count,
    output reg  [31:0]              completed_frame_count,

    output reg  [31:0]              last_adc_a_raw_pp,
    output reg  [31:0]              last_adc_b_raw_pp,
    output reg  [31:0]              last_adc_a_filt_pp,
    output reg  [31:0]              last_adc_b_filt_pp,
    output wire [31:0]              debug_status
);

    localparam [31:0] FRAME_MAGIC_U32       = 32'h3631_5246; // 'FR16'
    localparam [31:0] FOOTER_MAGIC_U32      = 32'h454E_4F44; // 'DONE'
    localparam [31:0] REAL_ADC_FLAG_U32     = 32'h0000_0002;
    localparam [31:0] HOST_TRIGGER_FLAG_U32 = 32'h0000_0004;
    localparam [15:0] FRAME_VERSION_U16     = 16'd3;
    localparam [15:0] FRAME_HEADER_BYTES_U16 = FRAME_HEADER_BYTES;

    localparam integer HEADER_WORDS          = FRAME_HEADER_BYTES / 4;
    localparam integer SENSOR_TIMELINE_ENTRY_WORDS = 10;
    localparam integer SENSOR_TIMELINE_ENTRY_BYTES = SENSOR_TIMELINE_ENTRY_WORDS * 4;
    localparam integer SENSOR_TIMELINE_WORDS = SENSOR_TIMELINE_DEPTH * SENSOR_TIMELINE_ENTRY_WORDS;
    localparam integer SENSOR_TIMELINE_BYTES = SENSOR_TIMELINE_DEPTH * SENSOR_TIMELINE_ENTRY_BYTES;
    localparam integer SENSOR_TIMELINE_ADDR_W = $clog2(SENSOR_TIMELINE_DEPTH);
    localparam integer SUMMARY_WORDS         = SUMMARY_BYTES / 4;
    localparam integer FOOTER_WORDS          = FOOTER_BYTES / 4;

    localparam [3:0] ST_IDLE      = 4'd0;
    localparam [3:0] ST_HEADER    = 4'd1;
    localparam [3:0] ST_WAVE      = 4'd2;
    localparam [3:0] ST_WAIT_DONE = 4'd3;
    localparam [3:0] ST_SENSOR    = 4'd4;
    localparam [3:0] ST_SUMMARY   = 4'd5;
    localparam [3:0] ST_FOOTER    = 4'd6;

    reg [3:0]  state;
    reg        start_pending;
    reg        adc_start_toggle;
    reg        adc_done_seen;
    reg [31:0] next_frame_id;
    reg [31:0] frame_id_latched;
    reg [31:0] header_index;
    reg [31:0] wave_index;
    reg [31:0] sensor_timeline_send_entry;
    reg [3:0]  sensor_timeline_send_word;
    reg [31:0] summary_index;
    reg [31:0] footer_index;

    // Runtime waveform length, latched from sample_count_cfg at capture start.
    reg [31:0] sample_count_latched;

    // Frame geometry derived from the latched runtime waveform length.
    wire [31:0] wave_bytes_rt    = sample_count_latched << 2;
    wire [31:0] timeline_off_rt  = FRAME_HEADER_BYTES + wave_bytes_rt;
    wire [31:0] summary_off_rt   = timeline_off_rt + SENSOR_TIMELINE_BYTES;
    wire [31:0] footer_off_rt    = summary_off_rt + SUMMARY_BYTES;
    wire [31:0] payload_bytes_rt = footer_off_rt + FOOTER_BYTES;
    wire [31:0] words_per_frame_rt = payload_bytes_rt >> 2;
    // capture duration in us = sample_count / 15.625 MHz; (x*131)>>11
    // approximates x*0.064 with <0.06% error (header is informational; host
    // can recompute exactly from sample_count and sample_rate_hz).
    wire [31:0] duration_us_rt   = (sample_count_latched * 32'd131) >> 11;

    reg signed [31:0] laser1_latched;
    reg signed [31:0] laser2_latched;
    reg signed [31:0] laser3_latched;
    reg signed [31:0] laser4_latched;
    reg signed [31:0] laser5_latched;
    reg signed [15:0] temp_latched;
    reg [5:0] valid_latched;
    reg [5:0] busy_latched;
    reg [5:0] crc_latched;
    reg [5:0] timeout_latched;
    reg [5:0] frame_error_latched;
    reg [1:0] adc_or_latched;
    reg       frame_fifo_overflow_latched;
    reg [31:0] overrun_at_start;
    reg [31:0] backpressure_at_start;
    reg [31:0] fifo_overflow_at_start;

    reg        sensor_capture_active;
    reg [31:0] sensor_us_counter;
    reg [5:0]  sensor_us_div;
    reg [31:0] sensor_sample_est;
    reg [4:0]  sensor_sample_frac;
    reg [31:0] sensor_timeline_count;
    reg [31:0] sensor_timeline_overflow_count;
    reg [319:0] sensor_timeline_read_data;

    (* ram_style = "block" *) reg [319:0] sensor_timeline_mem [0:SENSOR_TIMELINE_DEPTH-1];

    wire fifo_full;
    wire fifo_empty;
    wire [31:0] fifo_rd_data;
    wire fifo_rd_en;

    wire fire_word = m_axis_tvalid && m_axis_tready;
    wire [31:0] sensor_status_latched = {
        busy_latched,
        adc_or_latched,
        frame_error_latched,
        timeout_latched,
        crc_latched,
        valid_latched
    };
    wire [31:0] sensor_status_live = {
        sensor_busy,
        2'd0,
        sensor_frame_error,
        sensor_timeout_error,
        sensor_crc_error,
        sensor_valid_seen
    };
    wire sensor_timeline_event = sensor_capture_active && (|sensor_valid_pulse);
    wire [4:0] sensor_sample_frac_sum = sensor_sample_frac + 5'd5;
    wire [31:0] sensor_sample_record =
        (sensor_sample_est >= sample_count_latched) ? (sample_count_latched - 1) :
                                                      sensor_sample_est;
    wire sensor_start_accept = (state == ST_IDLE) && start_pending && enable;
    wire sensor_timeline_wr_event =
        sensor_timeline_event && (sensor_timeline_count < SENSOR_TIMELINE_DEPTH);
    wire sensor_timeline_wr_en = sensor_start_accept || sensor_timeline_wr_event;
    wire [SENSOR_TIMELINE_ADDR_W-1:0] sensor_timeline_wr_addr =
        sensor_start_accept ? {SENSOR_TIMELINE_ADDR_W{1'b0}} :
                              sensor_timeline_count[SENSOR_TIMELINE_ADDR_W-1:0];
    wire [319:0] sensor_timeline_start_record = {
        {{16{temperature_x10[15]}}, temperature_x10},
        laser5_um,
        laser4_um,
        laser3_um,
        laser2_um,
        laser1_um,
        sensor_status_live,
        32'd0,
        32'd0,
        32'd0
    };
    wire [319:0] sensor_timeline_event_record = {
        {{16{temperature_x10[15]}}, temperature_x10},
        laser5_um,
        laser4_um,
        laser3_um,
        laser2_um,
        laser1_um,
        sensor_status_live,
        {26'd0, sensor_valid_pulse},
        sensor_sample_record,
        sensor_us_counter
    };
    wire [319:0] sensor_timeline_wr_data =
        sensor_start_accept ? sensor_timeline_start_record : sensor_timeline_event_record;
    wire sensor_timeline_load_first = (state == ST_WAIT_DONE) && adc_done_seen;
    wire sensor_timeline_load_next =
        (state == ST_SENSOR) && fire_word &&
        (sensor_timeline_send_word == (SENSOR_TIMELINE_ENTRY_WORDS - 1)) &&
        (sensor_timeline_send_entry != (SENSOR_TIMELINE_DEPTH - 1)) &&
        ((sensor_timeline_send_entry + 1'b1) < sensor_timeline_count);
    wire sensor_timeline_rd_en = sensor_timeline_load_first || sensor_timeline_load_next;
    wire [SENSOR_TIMELINE_ADDR_W-1:0] sensor_timeline_rd_addr =
        sensor_timeline_load_next ?
            (sensor_timeline_send_entry[SENSOR_TIMELINE_ADDR_W-1:0] +
             {{(SENSOR_TIMELINE_ADDR_W-1){1'b0}}, 1'b1}) :
            {SENSOR_TIMELINE_ADDR_W{1'b0}};

    assign m_axis_tkeep = 4'hF;
    assign active       = (state != ST_IDLE) || start_pending;
    assign fifo_rd_en   = (state == ST_WAVE) && !fifo_empty && m_axis_tready;
    assign debug_status = {
        state,
        start_pending,
        enable,
        fifo_full,
        fifo_empty,
        adc_done_seen,
        frame_fifo_overflow_latched,
        22'd0
    };

    always @(posedge clk) begin
        if (sensor_timeline_wr_en)
            sensor_timeline_mem[sensor_timeline_wr_addr] <= sensor_timeline_wr_data;
        if (sensor_timeline_rd_en)
            sensor_timeline_read_data <= sensor_timeline_mem[sensor_timeline_rd_addr];
    end

    function [31:0] code_to_mvpp;
        input [31:0] code_pp;
        reg [63:0] scaled;
        begin
            scaled = (code_pp * 64'd9000) + 64'd32768;
            code_to_mvpp = scaled >> 16;
        end
    endfunction

    function [31:0] make_header_word;
        input [31:0] idx;
        begin
            case (idx)
                32'd0:  make_header_word = FRAME_MAGIC_U32;
                32'd1:  make_header_word = {FRAME_HEADER_BYTES_U16, FRAME_VERSION_U16};
                32'd2:  make_header_word = payload_bytes_rt;
                32'd3:  make_header_word = payload_bytes_rt;
                32'd4:  make_header_word = frame_id_latched;
                32'd5:  make_header_word = duration_us_rt;
                32'd6:  make_header_word = sample_count_latched;
                32'd7:  make_header_word = SAMPLE_RATE_HZ;
                32'd8:  make_header_word = REAL_ADC_FLAG_U32 | HOST_TRIGGER_FLAG_U32;
                32'd9:  make_header_word = sensor_status_latched;
                32'd10: make_header_word = FRAME_HEADER_BYTES;
                32'd11: make_header_word = wave_bytes_rt;
                32'd12: make_header_word = summary_off_rt;
                32'd13: make_header_word = SUMMARY_BYTES;
                32'd14: make_header_word = footer_off_rt;
                32'd15: make_header_word = FOOTER_BYTES;
                32'd16: make_header_word = payload_bytes_rt;
                32'd17: make_header_word = {26'd0, valid_latched};
                32'd18: make_header_word = overrun_at_start;
                32'd19: make_header_word = backpressure_at_start;
                32'd20: make_header_word = fifo_overflow_at_start;
                32'd21: make_header_word = timeline_off_rt;
                32'd22: make_header_word = SENSOR_TIMELINE_BYTES;
                32'd23: make_header_word = SENSOR_TIMELINE_DEPTH;
                32'd24: make_header_word = SENSOR_TIMELINE_ENTRY_BYTES;
                32'd25: make_header_word = 32'd0;
                default: make_header_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] make_summary_word;
        input [31:0] idx;
        begin
            case (idx)
                32'd0:  make_summary_word = last_adc_a_raw_pp;
                32'd1:  make_summary_word = last_adc_b_raw_pp;
                32'd2:  make_summary_word = last_adc_a_filt_pp;
                32'd3:  make_summary_word = last_adc_b_filt_pp;
                32'd4:  make_summary_word = code_to_mvpp(last_adc_a_filt_pp);
                32'd5:  make_summary_word = code_to_mvpp(last_adc_b_filt_pp);
                32'd6:  make_summary_word = laser1_latched;
                32'd7:  make_summary_word = laser2_latched;
                32'd8:  make_summary_word = laser3_latched;
                32'd9:  make_summary_word = laser4_latched;
                32'd10: make_summary_word = laser5_latched;
                32'd11: make_summary_word = {{16{temp_latched[15]}}, temp_latched};
                32'd12: make_summary_word = sensor_status_latched;
                32'd13: make_summary_word = frame_overrun_count;
                32'd14: make_summary_word = fifo_overflow_count;
                32'd15: make_summary_word = {31'd0, frame_fifo_overflow_latched};
                32'd16: make_summary_word = timeline_off_rt;
                32'd17: make_summary_word = SENSOR_TIMELINE_BYTES;
                32'd18: make_summary_word = sensor_timeline_count;
                32'd19: make_summary_word = SENSOR_TIMELINE_ENTRY_BYTES;
                32'd20: make_summary_word = sensor_timeline_overflow_count;
                default: make_summary_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] make_sensor_timeline_word;
        input [319:0] record_data;
        input [3:0] word_idx;
        begin
            case (word_idx)
                4'd0: make_sensor_timeline_word = record_data[31:0];
                4'd1: make_sensor_timeline_word = record_data[63:32];
                4'd2: make_sensor_timeline_word = record_data[95:64];
                4'd3: make_sensor_timeline_word = record_data[127:96];
                4'd4: make_sensor_timeline_word = record_data[159:128];
                4'd5: make_sensor_timeline_word = record_data[191:160];
                4'd6: make_sensor_timeline_word = record_data[223:192];
                4'd7: make_sensor_timeline_word = record_data[255:224];
                4'd8: make_sensor_timeline_word = record_data[287:256];
                4'd9: make_sensor_timeline_word = record_data[319:288];
                default: make_sensor_timeline_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] make_footer_word;
        input [31:0] idx;
        begin
            case (idx)
                32'd0: make_footer_word = FOOTER_MAGIC_U32;
                32'd1: make_footer_word = frame_id_latched;
                32'd2: make_footer_word = words_per_frame_rt;
                32'd3: make_footer_word = payload_bytes_rt;
                32'd4: make_footer_word = payload_bytes_rt;
                32'd5: make_footer_word = sample_count_latched;
                32'd6: make_footer_word = 32'd0;
                32'd7: make_footer_word = 32'd0;
                32'd8: make_footer_word = REAL_ADC_FLAG_U32 | HOST_TRIGGER_FLAG_U32 |
                                          {31'd0, frame_fifo_overflow_latched};
                32'd9: make_footer_word = sensor_timeline_count;
                default: make_footer_word = 32'd0;
            endcase
        end
    endfunction

    always @(*) begin
        m_axis_tdata  = 32'd0;
        m_axis_tvalid = 1'b0;
        m_axis_tlast  = 1'b0;

        case (state)
            ST_HEADER: begin
                m_axis_tdata  = make_header_word(header_index);
                m_axis_tvalid = 1'b1;
            end
            ST_WAVE: begin
                m_axis_tdata  = fifo_empty ? 32'd0 : fifo_rd_data;
                m_axis_tvalid = !fifo_empty ||
                                (adc_done_seen && frame_fifo_overflow_latched);
            end
            ST_SENSOR: begin
                m_axis_tdata  = (sensor_timeline_send_entry >= sensor_timeline_count) ?
                    32'd0 : make_sensor_timeline_word(sensor_timeline_read_data,
                                                       sensor_timeline_send_word);
                m_axis_tvalid = 1'b1;
            end
            ST_SUMMARY: begin
                m_axis_tdata  = make_summary_word(summary_index);
                m_axis_tvalid = 1'b1;
            end
            ST_FOOTER: begin
                m_axis_tdata  = make_footer_word(footer_index);
                m_axis_tvalid = 1'b1;
                m_axis_tlast  = (footer_index == (FOOTER_WORDS - 1));
            end
            default: begin
            end
        endcase
    end

    /*
     * ADC-domain capture engine
     */
    localparam integer FILT_LEN  = 16;
    localparam integer FILT_SHFT = 4;

    reg adc_start_s1;
    reg adc_start_s2;
    reg adc_start_s3;
    wire adc_start_pulse = adc_start_s2 ^ adc_start_s3;

    // Quasi-static CDC of the runtime waveform length into the ADC DCO domain.
    // sample_count_latched only changes while no capture is active, so a plain
    // two-flop synchronizer is sufficient.
    reg [31:0] adc_sample_count_s1;
    reg [31:0] adc_sample_count_s2;

    reg        adc_active;
    reg [31:0] adc_sample_index;
    reg        adc_done_toggle;
    reg        adc_frame_overflow;
    reg [1:0]  adc_or_accum;

    reg [31:0] adc_a_raw_pp_final;
    reg [31:0] adc_b_raw_pp_final;
    reg [31:0] adc_a_filt_pp_final;
    reg [31:0] adc_b_filt_pp_final;
    reg        adc_fifo_overflow_final;
    reg [1:0]  adc_or_final;

    wire signed [15:0] adc_ina_s = $signed(adc_ina);
    wire signed [15:0] adc_inb_s = $signed(adc_inb);

    reg signed [15:0] raw_min_a;
    reg signed [15:0] raw_max_a;
    reg signed [15:0] raw_min_b;
    reg signed [15:0] raw_max_b;

    reg signed [15:0] filt_shift_a [0:FILT_LEN-1];
    reg signed [15:0] filt_shift_b [0:FILT_LEN-1];
    reg signed [20:0] filt_sum_a;
    reg signed [20:0] filt_sum_b;
    reg signed [20:0] filt_min_a;
    reg signed [20:0] filt_max_a;
    reg signed [20:0] filt_min_b;
    reg signed [20:0] filt_max_b;

    wire signed [15:0] filt_oldest_a = filt_shift_a[FILT_LEN-1];
    wire signed [15:0] filt_oldest_b = filt_shift_b[FILT_LEN-1];
    wire signed [20:0] adc_ina_ext = {{5{adc_ina_s[15]}}, adc_ina_s};
    wire signed [20:0] adc_inb_ext = {{5{adc_inb_s[15]}}, adc_inb_s};
    wire signed [20:0] oldest_a_ext = {{5{filt_oldest_a[15]}}, filt_oldest_a};
    wire signed [20:0] oldest_b_ext = {{5{filt_oldest_b[15]}}, filt_oldest_b};
    wire signed [20:0] filt_sum_next_a = filt_sum_a + adc_ina_ext - oldest_a_ext;
    wire signed [20:0] filt_sum_next_b = filt_sum_b + adc_inb_ext - oldest_b_ext;
    wire filt_valid = (adc_sample_index >= (FILT_LEN - 1));

    wire signed [15:0] raw_min_next_a = (adc_sample_index == 32'd0) ? adc_ina_s :
                                        ((adc_ina_s < raw_min_a) ? adc_ina_s : raw_min_a);
    wire signed [15:0] raw_max_next_a = (adc_sample_index == 32'd0) ? adc_ina_s :
                                        ((adc_ina_s > raw_max_a) ? adc_ina_s : raw_max_a);
    wire signed [15:0] raw_min_next_b = (adc_sample_index == 32'd0) ? adc_inb_s :
                                        ((adc_inb_s < raw_min_b) ? adc_inb_s : raw_min_b);
    wire signed [15:0] raw_max_next_b = (adc_sample_index == 32'd0) ? adc_inb_s :
                                        ((adc_inb_s > raw_max_b) ? adc_inb_s : raw_max_b);

    wire signed [20:0] filt_min_next_a = (adc_sample_index == (FILT_LEN - 1)) ? filt_sum_next_a :
                                         ((filt_sum_next_a < filt_min_a) ? filt_sum_next_a : filt_min_a);
    wire signed [20:0] filt_max_next_a = (adc_sample_index == (FILT_LEN - 1)) ? filt_sum_next_a :
                                         ((filt_sum_next_a > filt_max_a) ? filt_sum_next_a : filt_max_a);
    wire signed [20:0] filt_min_next_b = (adc_sample_index == (FILT_LEN - 1)) ? filt_sum_next_b :
                                         ((filt_sum_next_b < filt_min_b) ? filt_sum_next_b : filt_min_b);
    wire signed [20:0] filt_max_next_b = (adc_sample_index == (FILT_LEN - 1)) ? filt_sum_next_b :
                                         ((filt_sum_next_b > filt_max_b) ? filt_sum_next_b : filt_max_b);

    wire adc_wr_sample = (adc_start_pulse && !adc_active) || adc_active;
    wire adc_fifo_wr_en = adc_wr_sample && !fifo_full;
    wire [31:0] adc_fifo_wr_data = {adc_inb, adc_ina};

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

    integer i;
    always @(posedge adc_dco or negedge rst_n) begin
        if (!rst_n) begin
            adc_start_s1           <= 1'b0;
            adc_start_s2           <= 1'b0;
            adc_start_s3           <= 1'b0;
            adc_sample_count_s1    <= SAMPLE_COUNT;
            adc_sample_count_s2    <= SAMPLE_COUNT;
            adc_active             <= 1'b0;
            adc_sample_index       <= 32'd0;
            adc_done_toggle        <= 1'b0;
            adc_frame_overflow     <= 1'b0;
            adc_or_accum           <= 2'd0;
            adc_a_raw_pp_final     <= 32'd0;
            adc_b_raw_pp_final     <= 32'd0;
            adc_a_filt_pp_final    <= 32'd0;
            adc_b_filt_pp_final    <= 32'd0;
            adc_fifo_overflow_final<= 1'b0;
            adc_or_final           <= 2'd0;
            raw_min_a              <= 16'sd0;
            raw_max_a              <= 16'sd0;
            raw_min_b              <= 16'sd0;
            raw_max_b              <= 16'sd0;
            filt_sum_a             <= 21'sd0;
            filt_sum_b             <= 21'sd0;
            filt_min_a             <= 21'sd0;
            filt_max_a             <= 21'sd0;
            filt_min_b             <= 21'sd0;
            filt_max_b             <= 21'sd0;
            for (i = 0; i < FILT_LEN; i = i + 1) begin
                filt_shift_a[i] <= 16'sd0;
                filt_shift_b[i] <= 16'sd0;
            end
        end else begin
            adc_start_s1 <= adc_start_toggle;
            adc_start_s2 <= adc_start_s1;
            adc_start_s3 <= adc_start_s2;
            adc_sample_count_s1 <= sample_count_latched;
            adc_sample_count_s2 <= adc_sample_count_s1;

            if (adc_start_pulse && !adc_active) begin
                filt_shift_a[0] <= adc_ina_s;
                filt_shift_b[0] <= adc_inb_s;
                for (i = 1; i < FILT_LEN; i = i + 1) begin
                    filt_shift_a[i] <= 16'sd0;
                    filt_shift_b[i] <= 16'sd0;
                end

                filt_sum_a         <= adc_ina_ext;
                filt_sum_b         <= adc_inb_ext;
                raw_min_a          <= adc_ina_s;
                raw_max_a          <= adc_ina_s;
                raw_min_b          <= adc_inb_s;
                raw_max_b          <= adc_inb_s;
                filt_min_a         <= 21'sd0;
                filt_max_a         <= 21'sd0;
                filt_min_b         <= 21'sd0;
                filt_max_b         <= 21'sd0;
                adc_frame_overflow <= fifo_full;
                adc_or_accum       <= {adc_orb, adc_ora};

                if (adc_sample_count_s2 == 32'd1) begin
                    adc_a_raw_pp_final      <= 32'd0;
                    adc_b_raw_pp_final      <= 32'd0;
                    adc_a_filt_pp_final     <= 32'd0;
                    adc_b_filt_pp_final     <= 32'd0;
                    adc_fifo_overflow_final <= fifo_full;
                    adc_or_final            <= {adc_orb, adc_ora};
                    adc_active              <= 1'b0;
                    adc_sample_index        <= 32'd0;
                    adc_done_toggle         <= ~adc_done_toggle;
                end else begin
                    adc_active       <= 1'b1;
                    adc_sample_index <= 32'd1;
                end
            end else if (adc_active) begin
                filt_shift_a[0] <= adc_ina_s;
                filt_shift_b[0] <= adc_inb_s;
                for (i = 1; i < FILT_LEN; i = i + 1) begin
                    filt_shift_a[i] <= filt_shift_a[i-1];
                    filt_shift_b[i] <= filt_shift_b[i-1];
                end

                filt_sum_a <= filt_sum_next_a;
                filt_sum_b <= filt_sum_next_b;
                raw_min_a  <= raw_min_next_a;
                raw_max_a  <= raw_max_next_a;
                raw_min_b  <= raw_min_next_b;
                raw_max_b  <= raw_max_next_b;
                adc_or_accum <= adc_or_accum | {adc_orb, adc_ora};
                if (fifo_full)
                    adc_frame_overflow <= 1'b1;

                if (filt_valid) begin
                    filt_min_a <= filt_min_next_a;
                    filt_max_a <= filt_max_next_a;
                    filt_min_b <= filt_min_next_b;
                    filt_max_b <= filt_max_next_b;
                end

                if (adc_sample_index == (adc_sample_count_s2 - 32'd1)) begin
                    adc_a_raw_pp_final <= {15'd0, diff_s16(raw_max_next_a, raw_min_next_a)};
                    adc_b_raw_pp_final <= {15'd0, diff_s16(raw_max_next_b, raw_min_next_b)};
                    if (filt_valid) begin
                        adc_a_filt_pp_final <= {10'd0, (diff_s21(filt_max_next_a, filt_min_next_a) >> FILT_SHFT)};
                        adc_b_filt_pp_final <= {10'd0, (diff_s21(filt_max_next_b, filt_min_next_b) >> FILT_SHFT)};
                    end else begin
                        adc_a_filt_pp_final <= 32'd0;
                        adc_b_filt_pp_final <= 32'd0;
                    end
                    adc_fifo_overflow_final <= adc_frame_overflow | fifo_full;
                    adc_or_final            <= adc_or_accum | {adc_orb, adc_ora};
                    adc_active              <= 1'b0;
                    adc_sample_index        <= 32'd0;
                    adc_done_toggle         <= ~adc_done_toggle;
                end else begin
                    adc_active       <= 1'b1;
                    adc_sample_index <= adc_sample_index + 1'b1;
                end
            end
        end
    end

    axis_async_fifo_32 #(
        .ADDR_WIDTH(FIFO_ADDR_WIDTH)
    ) u_adc_to_axis_fifo (
        .wr_clk   (adc_dco),
        .wr_rst_n (rst_n),
        .wr_en    (adc_fifo_wr_en),
        .wr_data  (adc_fifo_wr_data),
        .wr_full  (fifo_full),
        .rd_clk   (clk),
        .rd_rst_n (rst_n),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_rd_data),
        .rd_empty (fifo_empty)
    );

    reg adc_done_s1;
    reg adc_done_s2;
    reg adc_done_s3;
    wire adc_done_pulse_sys = adc_done_s2 ^ adc_done_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_done_s1                 <= 1'b0;
            adc_done_s2                 <= 1'b0;
            adc_done_s3                 <= 1'b0;
            state                       <= ST_IDLE;
            start_pending               <= 1'b0;
            adc_start_toggle            <= 1'b0;
            adc_done_seen               <= 1'b0;
            next_frame_id               <= 32'd0;
            frame_id_latched            <= 32'd0;
            header_index                <= 32'd0;
            wave_index                  <= 32'd0;
            sensor_timeline_send_entry  <= 32'd0;
            sensor_timeline_send_word   <= 4'd0;
            summary_index               <= 32'd0;
            footer_index                <= 32'd0;
            sample_count_latched        <= SAMPLE_COUNT;
            laser1_latched              <= 32'sd0;
            laser2_latched              <= 32'sd0;
            laser3_latched              <= 32'sd0;
            laser4_latched              <= 32'sd0;
            laser5_latched              <= 32'sd0;
            temp_latched                <= 16'sd0;
            valid_latched               <= 6'd0;
            busy_latched                <= 6'd0;
            crc_latched                 <= 6'd0;
            timeout_latched             <= 6'd0;
            frame_error_latched         <= 6'd0;
            adc_or_latched              <= 2'd0;
            frame_fifo_overflow_latched <= 1'b0;
            overrun_at_start            <= 32'd0;
            backpressure_at_start       <= 32'd0;
            fifo_overflow_at_start      <= 32'd0;
            sensor_capture_active       <= 1'b0;
            sensor_us_counter           <= 32'd0;
            sensor_us_div               <= 6'd0;
            sensor_sample_est           <= 32'd0;
            sensor_sample_frac          <= 5'd0;
            sensor_timeline_count       <= 32'd0;
            sensor_timeline_overflow_count <= 32'd0;
            last_completed_frame_id     <= 32'd0;
            frame_overrun_count         <= 32'd0;
            axis_backpressure_count     <= 32'd0;
            fifo_overflow_count         <= 32'd0;
            completed_frame_count       <= 32'd0;
            last_adc_a_raw_pp           <= 32'd0;
            last_adc_b_raw_pp           <= 32'd0;
            last_adc_a_filt_pp          <= 32'd0;
            last_adc_b_filt_pp          <= 32'd0;
        end else begin
            adc_done_s1 <= adc_done_toggle;
            adc_done_s2 <= adc_done_s1;
            adc_done_s3 <= adc_done_s2;

            if (capture_start_pulse) begin
                if ((state == ST_IDLE) && !start_pending) begin
                    start_pending <= 1'b1;
                end else begin
                    frame_overrun_count <= frame_overrun_count + 1'b1;
                end
            end

            if (m_axis_tvalid && !m_axis_tready)
                axis_backpressure_count <= axis_backpressure_count + 1'b1;

            if (adc_done_pulse_sys) begin
                adc_done_seen               <= 1'b1;
                sensor_capture_active       <= 1'b0;
                last_adc_a_raw_pp           <= adc_a_raw_pp_final;
                last_adc_b_raw_pp           <= adc_b_raw_pp_final;
                last_adc_a_filt_pp          <= adc_a_filt_pp_final;
                last_adc_b_filt_pp          <= adc_b_filt_pp_final;
                adc_or_latched              <= adc_or_final;
                frame_fifo_overflow_latched <= adc_fifo_overflow_final;
                if (adc_fifo_overflow_final)
                    fifo_overflow_count <= fifo_overflow_count + 1'b1;
            end

            if (sensor_capture_active) begin
                if (sensor_us_div == 6'd49) begin
                    sensor_us_div     <= 6'd0;
                    sensor_us_counter <= sensor_us_counter + 1'b1;
                end else begin
                    sensor_us_div <= sensor_us_div + 1'b1;
                end

                if (sensor_sample_est < sample_count_latched) begin
                    if (sensor_sample_frac_sum >= 5'd16) begin
                        sensor_sample_frac <= sensor_sample_frac_sum - 5'd16;
                        sensor_sample_est  <= sensor_sample_est + 1'b1;
                    end else begin
                        sensor_sample_frac <= sensor_sample_frac_sum;
                    end
                end
            end

            if (sensor_timeline_event) begin
                if (sensor_timeline_count < SENSOR_TIMELINE_DEPTH) begin
                    sensor_timeline_count <= sensor_timeline_count + 1'b1;
                end else begin
                    sensor_timeline_overflow_count <= sensor_timeline_overflow_count + 1'b1;
                end
            end

            case (state)
                ST_IDLE: begin
                    if (start_pending && enable) begin
                        next_frame_id          <= next_frame_id + 1'b1;
                        frame_id_latched       <= next_frame_id + 1'b1;
                        sample_count_latched   <= sample_count_cfg;
                        header_index           <= 32'd0;
                        wave_index             <= 32'd0;
                        sensor_timeline_send_entry <= 32'd0;
                        sensor_timeline_send_word  <= 4'd0;
                        summary_index          <= 32'd0;
                        footer_index           <= 32'd0;
                        adc_done_seen          <= 1'b0;
                        frame_fifo_overflow_latched <= 1'b0;
                        laser1_latched         <= laser1_um;
                        laser2_latched         <= laser2_um;
                        laser3_latched         <= laser3_um;
                        laser4_latched         <= laser4_um;
                        laser5_latched         <= laser5_um;
                        temp_latched           <= temperature_x10;
                        valid_latched          <= sensor_valid_seen;
                        busy_latched           <= sensor_busy;
                        crc_latched            <= sensor_crc_error;
                        timeout_latched        <= sensor_timeout_error;
                        frame_error_latched    <= sensor_frame_error;
                        adc_or_latched         <= 2'd0;
                        overrun_at_start       <= frame_overrun_count;
                        backpressure_at_start  <= axis_backpressure_count;
                        fifo_overflow_at_start <= fifo_overflow_count;
                        sensor_capture_active  <= 1'b1;
                        sensor_us_counter      <= 32'd0;
                        sensor_us_div          <= 6'd0;
                        sensor_sample_est      <= 32'd0;
                        sensor_sample_frac     <= 5'd0;
                        sensor_timeline_count  <= 32'd1;
                        sensor_timeline_overflow_count <= 32'd0;
                        adc_start_toggle       <= ~adc_start_toggle;
                        start_pending          <= 1'b0;
                        state                  <= ST_HEADER;
                    end
                end

                ST_HEADER: begin
                    if (fire_word) begin
                        if (header_index == (HEADER_WORDS - 1)) begin
                            wave_index <= 32'd0;
                            state      <= ST_WAVE;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end
                end

                ST_WAVE: begin
                    if (fire_word) begin
                        if (wave_index == (sample_count_latched - 32'd1)) begin
                            state <= ST_WAIT_DONE;
                        end else begin
                            wave_index <= wave_index + 1'b1;
                        end
                    end
                end

                ST_WAIT_DONE: begin
                    if (adc_done_seen) begin
                        sensor_timeline_send_entry <= 32'd0;
                        sensor_timeline_send_word  <= 4'd0;
                        state                      <= ST_SENSOR;
                    end
                end

                ST_SENSOR: begin
                    if (fire_word) begin
                        if ((sensor_timeline_send_entry == (SENSOR_TIMELINE_DEPTH - 1)) &&
                            (sensor_timeline_send_word == (SENSOR_TIMELINE_ENTRY_WORDS - 1))) begin
                            summary_index <= 32'd0;
                            state         <= ST_SUMMARY;
                        end else if (sensor_timeline_send_word == (SENSOR_TIMELINE_ENTRY_WORDS - 1)) begin
                            sensor_timeline_send_word  <= 4'd0;
                            sensor_timeline_send_entry <= sensor_timeline_send_entry + 1'b1;
                        end else begin
                            sensor_timeline_send_word <= sensor_timeline_send_word + 1'b1;
                        end
                    end
                end

                ST_SUMMARY: begin
                    if (fire_word) begin
                        if (summary_index == (SUMMARY_WORDS - 1)) begin
                            footer_index <= 32'd0;
                            state        <= ST_FOOTER;
                        end else begin
                            summary_index <= summary_index + 1'b1;
                        end
                    end
                end

                ST_FOOTER: begin
                    if (fire_word) begin
                        if (footer_index == (FOOTER_WORDS - 1)) begin
                            last_completed_frame_id <= frame_id_latched;
                            completed_frame_count   <= completed_frame_count + 1'b1;
                            state                   <= ST_IDLE;
                        end else begin
                            footer_index <= footer_index + 1'b1;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

module axis_async_fifo_32 #(
    parameter integer ADDR_WIDTH = 10
)(
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        wr_en,
    input  wire [31:0] wr_data,
    output wire        wr_full,

    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        rd_en,
    output wire [31:0] rd_data,
    output wire        rd_empty
);
    localparam integer DEPTH = (1 << ADDR_WIDTH);

    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH-1];

    reg [ADDR_WIDTH:0] wbin;
    reg [ADDR_WIDTH:0] wgray;
    reg [ADDR_WIDTH:0] rbin;
    reg [ADDR_WIDTH:0] rgray;
    reg [31:0] rd_data_reg;
    reg        rd_valid;

    reg [ADDR_WIDTH:0] rgray_wclk_s1;
    reg [ADDR_WIDTH:0] rgray_wclk_s2;
    reg [ADDR_WIDTH:0] wgray_rclk_s1;
    reg [ADDR_WIDTH:0] wgray_rclk_s2;

    wire [ADDR_WIDTH:0] wbin_plus_one  = wbin + {{ADDR_WIDTH{1'b0}}, 1'b1};
    wire [ADDR_WIDTH:0] wgray_plus_one = (wbin_plus_one >> 1) ^ wbin_plus_one;
    wire wr_fire = wr_en && !wr_full;
    wire rd_fire = rd_en && rd_valid;
    wire rd_mem_available = (rgray != wgray_rclk_s2);
    wire rd_fetch = !rd_valid && rd_mem_available;

    wire [ADDR_WIDTH:0] wbin_next  = wr_fire ? wbin_plus_one : wbin;
    wire [ADDR_WIDTH:0] rbin_plus_one = rbin + {{ADDR_WIDTH{1'b0}}, 1'b1};
    wire [ADDR_WIDTH:0] rbin_next  = rd_fetch ? rbin_plus_one : rbin;
    wire [ADDR_WIDTH:0] wgray_next = (wbin_next >> 1) ^ wbin_next;
    wire [ADDR_WIDTH:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    assign wr_full = (wgray_plus_one == {~rgray_wclk_s2[ADDR_WIDTH:ADDR_WIDTH-1],
                                         rgray_wclk_s2[ADDR_WIDTH-2:0]});
    assign rd_empty = !rd_valid;
    assign rd_data = rd_data_reg;

    always @(posedge wr_clk) begin
        if (wr_fire)
            mem[wbin[ADDR_WIDTH-1:0]] <= wr_data;
    end

    always @(posedge rd_clk) begin
        if (rd_fetch)
            rd_data_reg <= mem[rbin[ADDR_WIDTH-1:0]];
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin          <= {(ADDR_WIDTH+1){1'b0}};
            wgray         <= {(ADDR_WIDTH+1){1'b0}};
            rgray_wclk_s1 <= {(ADDR_WIDTH+1){1'b0}};
            rgray_wclk_s2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rgray_wclk_s1 <= rgray;
            rgray_wclk_s2 <= rgray_wclk_s1;
            if (wr_fire) begin
                wbin  <= wbin_next;
                wgray <= wgray_next;
            end
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin          <= {(ADDR_WIDTH+1){1'b0}};
            rgray         <= {(ADDR_WIDTH+1){1'b0}};
            rd_valid      <= 1'b0;
            wgray_rclk_s1 <= {(ADDR_WIDTH+1){1'b0}};
            wgray_rclk_s2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wgray_rclk_s1 <= wgray;
            wgray_rclk_s2 <= wgray_rclk_s1;

            if (rd_fetch) begin
                rbin  <= rbin_next;
                rgray <= rgray_next;
                rd_valid <= 1'b1;
            end else if (rd_fire) begin
                rd_valid <= 1'b0;
            end
        end
    end

endmodule
