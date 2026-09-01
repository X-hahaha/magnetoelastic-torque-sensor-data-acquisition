`timescale 1ns / 1ps
/*
 * fr16_test_frame_axis.v
 *
 * M1-only FR16 test frame generator for the 5000 frame/s DDR/DMA refactor.
 * This module deliberately does NOT consume the real ADC waveform yet.  It emits
 * one fixed-size 8192-byte AXI4-Stream packet per frame so the Vivado M0 block
 * design and PS S2MM SG ring can be validated before M2 connects the real ADC.
 *
 * DDR record order follows Scheme A from the handoff document:
 *   header -> waveform -> final_summary -> padding -> footer_done/TLAST
 *
 * Word format is little-endian compatible with the C structs used by PS.
 */
module fr16_test_frame_axis #(
    parameter integer CLK_FREQ_HZ         = 50_000_000,
    parameter integer PERIOD_US           = 200,
    parameter integer FRAME_STRIDE_BYTES  = 8192,
    parameter integer FRAME_HEADER_BYTES  = 256,
    parameter integer SAMPLE_COUNT        = 1562,
    parameter integer SAMPLE_RATE_HZ      = 15_625_000,
    parameter integer SUMMARY_BYTES       = 128,
    parameter integer FOOTER_BYTES        = 40
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    output reg  [31:0] m_axis_tdata,
    output wire [3:0]  m_axis_tkeep,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,

    output reg  [31:0] last_completed_frame_id,
    output reg  [31:0] active_frame_id,
    output reg  [31:0] frame_overrun_count,
    output reg  [31:0] axis_backpressure_count,
    output reg  [31:0] completed_frame_count
);

    localparam [31:0] FRAME_MAGIC_U32       = 32'h3631_5246; // 'FR16'
    localparam [31:0] FRAME_FOOTER_MAGIC    = 32'h454E_4F44; // 'DONE'
    localparam integer FRAME_VERSION        = 1;

    localparam [15:0] FRAME_VERSION_U16        = FRAME_VERSION;
    localparam [15:0] FRAME_HEADER_BYTES_U16   = FRAME_HEADER_BYTES;
    localparam [31:0] FRAME_STRIDE_BYTES_U32   = FRAME_STRIDE_BYTES;
    localparam [31:0] PERIOD_US_U32            = PERIOD_US;
    localparam [31:0] SAMPLE_COUNT_U32         = SAMPLE_COUNT;
    localparam [31:0] SAMPLE_RATE_HZ_U32       = SAMPLE_RATE_HZ;
    localparam [31:0] WAVE_OFFSET_BYTES_U32    = FRAME_HEADER_BYTES;
    localparam integer PERIOD_CLKS          = (CLK_FREQ_HZ / 1_000_000) * PERIOD_US;
    localparam integer WORDS_PER_FRAME      = FRAME_STRIDE_BYTES / 4;
    localparam integer HEADER_WORDS         = FRAME_HEADER_BYTES / 4;
    localparam integer WAVE_WORDS           = SAMPLE_COUNT;
    localparam integer WAVE_BYTES           = SAMPLE_COUNT * 4;
    localparam integer SUMMARY_WORDS        = SUMMARY_BYTES / 4;
    localparam integer FOOTER_WORDS         = FOOTER_BYTES / 4;
    localparam integer WAVE_OFFSET_BYTES    = FRAME_HEADER_BYTES;
    localparam integer SUMMARY_OFFSET_BYTES = FRAME_HEADER_BYTES + WAVE_BYTES;
    localparam integer SUMMARY_START_WORD   = SUMMARY_OFFSET_BYTES / 4;
    localparam integer FOOTER_OFFSET_BYTES  = FRAME_STRIDE_BYTES - FOOTER_BYTES;
    localparam integer FOOTER_START_WORD    = FOOTER_OFFSET_BYTES / 4;
    localparam integer PAYLOAD_BYTES        = FRAME_HEADER_BYTES + WAVE_BYTES + SUMMARY_BYTES + FOOTER_BYTES;
    localparam [31:0] WAVE_BYTES_U32           = WAVE_BYTES;
    localparam [31:0] SUMMARY_OFFSET_BYTES_U32 = SUMMARY_OFFSET_BYTES;
    localparam [31:0] SUMMARY_BYTES_U32        = SUMMARY_BYTES;
    localparam [31:0] FOOTER_OFFSET_BYTES_U32  = FOOTER_OFFSET_BYTES;
    localparam [31:0] FOOTER_BYTES_U32         = FOOTER_BYTES;
    localparam [31:0] PAYLOAD_BYTES_U32        = PAYLOAD_BYTES;
    localparam [31:0] WORDS_PER_FRAME_U32      = WORDS_PER_FRAME;

    assign m_axis_tkeep = 4'hF;

    reg [31:0] period_cnt;
    reg [31:0] word_index;
    reg        active;
    reg [31:0] next_frame_id;

    wire start_tick = enable && (period_cnt >= (PERIOD_CLKS - 1));
    wire fire_word  = m_axis_tvalid && m_axis_tready;
    wire last_word  = (word_index == (WORDS_PER_FRAME - 1));

    function [31:0] make_header_word;
        input [31:0] idx;
        input [31:0] fid;
        begin
            case (idx)
                32'd0:  make_header_word = FRAME_MAGIC_U32;
                32'd1:  make_header_word = {FRAME_HEADER_BYTES_U16, FRAME_VERSION_U16};
                32'd2:  make_header_word = FRAME_STRIDE_BYTES_U32;
                32'd3:  make_header_word = FRAME_STRIDE_BYTES_U32;
                32'd4:  make_header_word = fid;
                32'd5:  make_header_word = PERIOD_US_U32;
                32'd6:  make_header_word = SAMPLE_COUNT_U32;
                32'd7:  make_header_word = SAMPLE_RATE_HZ_U32;
                32'd8:  make_header_word = 32'h0000_0001; // bit0: M1 synthetic/test frame
                32'd9:  make_header_word = 32'd0;
                32'd10: make_header_word = WAVE_OFFSET_BYTES_U32;
                32'd11: make_header_word = WAVE_BYTES_U32;
                32'd12: make_header_word = SUMMARY_OFFSET_BYTES_U32;
                32'd13: make_header_word = SUMMARY_BYTES_U32;
                32'd14: make_header_word = FOOTER_OFFSET_BYTES_U32;
                32'd15: make_header_word = FOOTER_BYTES_U32;
                32'd16: make_header_word = PAYLOAD_BYTES_U32;
                32'd17: make_header_word = 32'd0; // sensor_update_mask
                32'd18: make_header_word = frame_overrun_count;
                32'd19: make_header_word = axis_backpressure_count;
                32'd20: make_header_word = 32'd0; // axis_fifo_overflow_count, external FIFO not visible here
                default: make_header_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] make_wave_word;
        input [31:0] idx;
        reg [15:0] sample_idx;
        reg [15:0] sample_a;
        reg [15:0] sample_b;
        begin
            sample_idx = idx[15:0];
            sample_a = sample_idx;
            sample_b = ~sample_idx;
            make_wave_word = {sample_b, sample_a};
        end
    endfunction

    function [31:0] make_summary_word;
        input [31:0] idx;
        begin
            case (idx)
                32'd0:  make_summary_word = (SAMPLE_COUNT - 1); // adc_a_raw_pp, synthetic ramp
                32'd1:  make_summary_word = (SAMPLE_COUNT - 1); // adc_b_raw_pp, synthetic inverse ramp
                32'd2:  make_summary_word = (SAMPLE_COUNT - 1); // adc_a_filt_pp placeholder
                32'd3:  make_summary_word = (SAMPLE_COUNT - 1); // adc_b_filt_pp placeholder
                32'd4:  make_summary_word = 32'd214;            // adc_a_mVpp placeholder
                32'd5:  make_summary_word = 32'd214;            // adc_b_mVpp placeholder
                default: make_summary_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] make_footer_word;
        input [31:0] idx;
        input [31:0] fid;
        begin
            case (idx)
                32'd0:  make_footer_word = FRAME_FOOTER_MAGIC;
                32'd1:  make_footer_word = fid;
                32'd2:  make_footer_word = WORDS_PER_FRAME_U32;
                32'd3:  make_footer_word = FRAME_STRIDE_BYTES_U32;
                32'd4:  make_footer_word = PAYLOAD_BYTES_U32;
                32'd5:  make_footer_word = SAMPLE_COUNT_U32;
                32'd6:  make_footer_word = 32'd0; // summary_crc, reserved for M2+
                32'd7:  make_footer_word = 32'd0; // wave_crc, reserved for M2+
                32'd8:  make_footer_word = 32'h0000_0001; // bit0: M1 synthetic/test frame
                default: make_footer_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] make_frame_word;
        input [31:0] idx;
        input [31:0] fid;
        begin
            if (idx < HEADER_WORDS) begin
                make_frame_word = make_header_word(idx, fid);
            end else if (idx < (HEADER_WORDS + WAVE_WORDS)) begin
                make_frame_word = make_wave_word(idx - HEADER_WORDS);
            end else if ((idx >= SUMMARY_START_WORD) &&
                         (idx < (SUMMARY_START_WORD + SUMMARY_WORDS))) begin
                make_frame_word = make_summary_word(idx - SUMMARY_START_WORD);
            end else if (idx >= FOOTER_START_WORD) begin
                make_frame_word = make_footer_word(idx - FOOTER_START_WORD, fid);
            end else begin
                make_frame_word = 32'd0; // padding
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            period_cnt               <= 32'd0;
            word_index               <= 32'd0;
            active                   <= 1'b0;
            next_frame_id            <= 32'd1;
            active_frame_id          <= 32'd0;
            last_completed_frame_id  <= 32'd0;
            frame_overrun_count      <= 32'd0;
            axis_backpressure_count  <= 32'd0;
            completed_frame_count    <= 32'd0;
            m_axis_tdata             <= 32'd0;
            m_axis_tvalid            <= 1'b0;
            m_axis_tlast             <= 1'b0;
        end else begin
            if (!enable) begin
                period_cnt    <= 32'd0;
                active        <= 1'b0;
                word_index    <= 32'd0;
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                m_axis_tdata  <= 32'd0;
            end else begin
                if (period_cnt >= (PERIOD_CLKS - 1)) begin
                    period_cnt <= 32'd0;
                end else begin
                    period_cnt <= period_cnt + 1'b1;
                end

                if (start_tick) begin
                    if (active) begin
                        frame_overrun_count <= frame_overrun_count + 1'b1;
                    end else begin
                        active          <= 1'b1;
                        word_index      <= 32'd0;
                        active_frame_id <= next_frame_id;
                        m_axis_tvalid   <= 1'b1;
                        m_axis_tdata    <= make_frame_word(32'd0, next_frame_id);
                        m_axis_tlast    <= (WORDS_PER_FRAME == 1);
                    end
                end

                if (active && m_axis_tvalid && !m_axis_tready) begin
                    axis_backpressure_count <= axis_backpressure_count + 1'b1;
                end

                if (fire_word) begin
                    if (last_word) begin
                        active                  <= 1'b0;
                        m_axis_tvalid           <= 1'b0;
                        m_axis_tlast            <= 1'b0;
                        m_axis_tdata            <= 32'd0;
                        last_completed_frame_id <= active_frame_id;
                        completed_frame_count   <= completed_frame_count + 1'b1;
                        next_frame_id           <= next_frame_id + 1'b1;
                        word_index              <= 32'd0;
                    end else begin
                        word_index    <= word_index + 1'b1;
                        m_axis_tdata  <= make_frame_word(word_index + 1'b1, active_frame_id);
                        m_axis_tlast  <= (word_index + 1'b1 == (WORDS_PER_FRAME - 1));
                    end
                end
            end
        end
    end

endmodule
