`timescale 1ns / 1ps
/*
 * fr16_adc_frame_axis.v
 *
 * M2 real-ADC FR16 frame packer.
 *
 * The existing ADC capture core writes one acquisition into a double-buffered
 * BRAM bank in the ADC DCO clock domains.  After capture_done_pulse, this module
 * latches the completed bank and all final summary values, reads exactly
 * SAMPLE_COUNT real sample pairs from that bank, and emits one fixed-size FR16
 * AXI4-Stream packet:
 *
 *   256-byte header -> real A/B waveform -> 128-byte final summary
 *   -> zero padding -> 40-byte DONE footer/TLAST
 *
 * The BRAM read interface has one CLK cycle latency. A sample is requested in
 * ST_WAVE_REQ; on the next cycle the BRAM output is driven directly in
 * ST_WAVE_SEND and remains stable until AXI4-Stream accepts it.
 */
module fr16_adc_frame_axis #(
    parameter integer PERIOD_US          = 200,
    parameter integer FRAME_STRIDE_BYTES = 8192,
    parameter integer FRAME_HEADER_BYTES = 256,
    parameter integer SAMPLE_COUNT       = 1562,
    parameter integer SAMPLE_RATE_HZ     = 15_625_000,
    parameter integer SUMMARY_BYTES      = 128,
    parameter integer FOOTER_BYTES       = 40,
    parameter integer ADC_ADDR_WIDTH     = 12
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     enable,

    input  wire                     capture_done_pulse,
    input  wire                     period_overrun_pulse,
    input  wire [31:0]              capture_id,
    input  wire                     completed_bank,

    input  wire [31:0]              adc_a_raw_pp,
    input  wire [31:0]              adc_b_raw_pp,
    input  wire [31:0]              adc_a_filt_pp,
    input  wire [31:0]              adc_b_filt_pp,

    input  wire signed [31:0]       laser1_um,
    input  wire signed [31:0]       laser2_um,
    input  wire signed [31:0]       laser3_um,
    input  wire signed [31:0]       laser4_um,
    input  wire signed [31:0]       laser5_um,
    input  wire signed [15:0]       temperature_x10,
    input  wire [5:0]               sensor_valid_seen,
    input  wire [5:0]               sensor_busy,
    input  wire [5:0]               sensor_crc_error,
    input  wire [5:0]               sensor_timeout_error,
    input  wire [5:0]               sensor_frame_error,
    input  wire [1:0]               adc_overrange,

    output reg                      adc_rd_en,
    output reg  [ADC_ADDR_WIDTH-1:0] adc_rd_addr,
    output wire                     adc_rd_bank,
    input  wire [31:0]              adc_rd_data_pair,

    output reg  [31:0]              m_axis_tdata,
    output wire [3:0]               m_axis_tkeep,
    output reg                      m_axis_tvalid,
    input  wire                     m_axis_tready,
    output reg                      m_axis_tlast,

    output wire                     active,
    output reg  [31:0]              last_completed_frame_id,
    output reg  [31:0]              frame_overrun_count,
    output reg  [31:0]              axis_backpressure_count,
    output reg  [31:0]              completed_frame_count
);

    localparam [31:0] FRAME_MAGIC_U32    = 32'h3631_5246; // 'FR16'
    localparam [31:0] FOOTER_MAGIC_U32   = 32'h454E_4F44; // 'DONE'
    localparam [31:0] REAL_ADC_FLAG_U32  = 32'h0000_0002; // bit1: real ADC frame
    localparam [15:0] FRAME_VERSION_U16  = 16'd1;
    localparam [15:0] FRAME_HEADER_BYTES_U16 = FRAME_HEADER_BYTES;

    localparam integer HEADER_WORDS         = FRAME_HEADER_BYTES / 4;
    localparam integer WAVE_WORDS           = SAMPLE_COUNT;
    localparam integer WAVE_BYTES           = SAMPLE_COUNT * 4;
    localparam integer SUMMARY_WORDS        = SUMMARY_BYTES / 4;
    localparam integer FOOTER_WORDS         = FOOTER_BYTES / 4;
    localparam integer WORDS_PER_FRAME      = FRAME_STRIDE_BYTES / 4;
    localparam integer SUMMARY_OFFSET_BYTES = FRAME_HEADER_BYTES + WAVE_BYTES;
    localparam integer FOOTER_OFFSET_BYTES  = FRAME_STRIDE_BYTES - FOOTER_BYTES;
    localparam integer FOOTER_START_WORD    = FOOTER_OFFSET_BYTES / 4;
    localparam integer SUMMARY_START_WORD   = SUMMARY_OFFSET_BYTES / 4;
    localparam integer PADDING_WORDS        = FOOTER_START_WORD - (SUMMARY_START_WORD + SUMMARY_WORDS);
    localparam integer PAYLOAD_BYTES        = FRAME_HEADER_BYTES + WAVE_BYTES + SUMMARY_BYTES + FOOTER_BYTES;

    localparam [3:0] ST_IDLE      = 4'd0;
    localparam [3:0] ST_HEADER    = 4'd1;
    localparam [3:0] ST_WAVE_REQ  = 4'd2;
    localparam [3:0] ST_WAVE_SEND = 4'd3;
    localparam [3:0] ST_SUMMARY   = 4'd5;
    localparam [3:0] ST_PADDING   = 4'd6;
    localparam [3:0] ST_FOOTER    = 4'd7;

    reg [3:0] state;
    reg [31:0] header_index;
    reg [31:0] wave_index;
    reg [31:0] summary_index;
    reg [31:0] padding_index;
    reg [31:0] footer_index;

    reg        frame_bank_latched;
    reg [31:0] frame_id_latched;
    reg [31:0] raw_pp_a_latched;
    reg [31:0] raw_pp_b_latched;
    reg [31:0] filt_pp_a_latched;
    reg [31:0] filt_pp_b_latched;
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
    reg [31:0] overrun_at_start;
    reg [31:0] backpressure_at_start;

    wire fire_word = m_axis_tvalid && m_axis_tready;
    wire [31:0] sensor_status_latched = {
        busy_latched,
        adc_or_latched,
        frame_error_latched,
        timeout_latched,
        crc_latched,
        valid_latched
    };

    assign m_axis_tkeep = 4'hF;
    assign adc_rd_bank  = frame_bank_latched;
    assign active       = (state != ST_IDLE);

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
                32'd2:  make_header_word = FRAME_STRIDE_BYTES;
                32'd3:  make_header_word = FRAME_STRIDE_BYTES;
                32'd4:  make_header_word = frame_id_latched;
                32'd5:  make_header_word = PERIOD_US;
                32'd6:  make_header_word = SAMPLE_COUNT;
                32'd7:  make_header_word = SAMPLE_RATE_HZ;
                32'd8:  make_header_word = REAL_ADC_FLAG_U32;
                32'd9:  make_header_word = sensor_status_latched;
                32'd10: make_header_word = FRAME_HEADER_BYTES;
                32'd11: make_header_word = WAVE_BYTES;
                32'd12: make_header_word = SUMMARY_OFFSET_BYTES;
                32'd13: make_header_word = SUMMARY_BYTES;
                32'd14: make_header_word = FOOTER_OFFSET_BYTES;
                32'd15: make_header_word = FOOTER_BYTES;
                32'd16: make_header_word = PAYLOAD_BYTES;
                32'd17: make_header_word = {26'd0, valid_latched};
                32'd18: make_header_word = overrun_at_start;
                32'd19: make_header_word = backpressure_at_start;
                32'd20: make_header_word = 32'd0;
                default: make_header_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] make_summary_word;
        input [31:0] idx;
        begin
            case (idx)
                32'd0:  make_summary_word = raw_pp_a_latched;
                32'd1:  make_summary_word = raw_pp_b_latched;
                32'd2:  make_summary_word = filt_pp_a_latched;
                32'd3:  make_summary_word = filt_pp_b_latched;
                32'd4:  make_summary_word = code_to_mvpp(filt_pp_a_latched);
                32'd5:  make_summary_word = code_to_mvpp(filt_pp_b_latched);
                32'd6:  make_summary_word = laser1_latched;
                32'd7:  make_summary_word = laser2_latched;
                32'd8:  make_summary_word = laser3_latched;
                32'd9:  make_summary_word = laser4_latched;
                32'd10: make_summary_word = laser5_latched;
                32'd11: make_summary_word = {{16{temp_latched[15]}}, temp_latched};
                32'd12: make_summary_word = sensor_status_latched;
                32'd13: make_summary_word = frame_overrun_count;
                default: make_summary_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] make_footer_word;
        input [31:0] idx;
        begin
            case (idx)
                32'd0: make_footer_word = FOOTER_MAGIC_U32;
                32'd1: make_footer_word = frame_id_latched;
                32'd2: make_footer_word = WORDS_PER_FRAME;
                32'd3: make_footer_word = FRAME_STRIDE_BYTES;
                32'd4: make_footer_word = PAYLOAD_BYTES;
                32'd5: make_footer_word = SAMPLE_COUNT;
                32'd6: make_footer_word = 32'd0;
                32'd7: make_footer_word = 32'd0;
                32'd8: make_footer_word = REAL_ADC_FLAG_U32;
                default: make_footer_word = 32'd0;
            endcase
        end
    endfunction

    always @(*) begin
        adc_rd_en    = 1'b0;
        adc_rd_addr  = wave_index[ADC_ADDR_WIDTH-1:0];
        m_axis_tdata = 32'd0;
        m_axis_tvalid= 1'b0;
        m_axis_tlast = 1'b0;

        case (state)
            ST_HEADER: begin
                m_axis_tdata  = make_header_word(header_index);
                m_axis_tvalid = 1'b1;
            end
            ST_WAVE_REQ: begin
                adc_rd_en   = 1'b1;
                adc_rd_addr = wave_index[ADC_ADDR_WIDTH-1:0];
            end
            ST_WAVE_SEND: begin
                // BRAM output was registered by the preceding ST_WAVE_REQ edge.
                // No further read is issued while stalled, so TDATA stays stable.
                m_axis_tdata  = adc_rd_data_pair;
                m_axis_tvalid = 1'b1;
            end
            ST_SUMMARY: begin
                m_axis_tdata  = make_summary_word(summary_index);
                m_axis_tvalid = 1'b1;
            end
            ST_PADDING: begin
                m_axis_tdata  = 32'd0;
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                       <= ST_IDLE;
            header_index                <= 32'd0;
            wave_index                  <= 32'd0;
            summary_index               <= 32'd0;
            padding_index               <= 32'd0;
            footer_index                <= 32'd0;
            frame_bank_latched          <= 1'b0;
            frame_id_latched            <= 32'd0;
            raw_pp_a_latched            <= 32'd0;
            raw_pp_b_latched            <= 32'd0;
            filt_pp_a_latched           <= 32'd0;
            filt_pp_b_latched           <= 32'd0;
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
            overrun_at_start            <= 32'd0;
            backpressure_at_start       <= 32'd0;
            last_completed_frame_id     <= 32'd0;
            frame_overrun_count         <= 32'd0;
            axis_backpressure_count     <= 32'd0;
            completed_frame_count       <= 32'd0;
        end else begin
            if (m_axis_tvalid && !m_axis_tready)
                axis_backpressure_count <= axis_backpressure_count + 1'b1;

            if (enable && (period_overrun_pulse ||
                (capture_done_pulse && (state != ST_IDLE))))
                frame_overrun_count <= frame_overrun_count + 1'b1;

            case (state)
                ST_IDLE: begin
                    if (capture_done_pulse && enable) begin
                        frame_bank_latched    <= completed_bank;
                        frame_id_latched      <= capture_id;
                        raw_pp_a_latched      <= adc_a_raw_pp;
                        raw_pp_b_latched      <= adc_b_raw_pp;
                        filt_pp_a_latched     <= adc_a_filt_pp;
                        filt_pp_b_latched     <= adc_b_filt_pp;
                        laser1_latched        <= laser1_um;
                        laser2_latched        <= laser2_um;
                        laser3_latched        <= laser3_um;
                        laser4_latched        <= laser4_um;
                        laser5_latched        <= laser5_um;
                        temp_latched          <= temperature_x10;
                        valid_latched         <= sensor_valid_seen;
                        busy_latched          <= sensor_busy;
                        crc_latched           <= sensor_crc_error;
                        timeout_latched       <= sensor_timeout_error;
                        frame_error_latched   <= sensor_frame_error;
                        adc_or_latched        <= adc_overrange;
                        overrun_at_start      <= frame_overrun_count;
                        backpressure_at_start <= axis_backpressure_count;
                        header_index          <= 32'd0;
                        state                 <= ST_HEADER;
                    end
                end

                ST_HEADER: begin
                    if (fire_word) begin
                        if (header_index == (HEADER_WORDS - 1)) begin
                            wave_index <= 32'd0;
                            state      <= ST_WAVE_REQ;
                        end else begin
                            header_index <= header_index + 1'b1;
                        end
                    end
                end

                ST_WAVE_REQ: begin
                    state <= ST_WAVE_SEND;
                end

                ST_WAVE_SEND: begin
                    if (fire_word) begin
                        if (wave_index == (WAVE_WORDS - 1)) begin
                            summary_index <= 32'd0;
                            state         <= ST_SUMMARY;
                        end else begin
                            wave_index <= wave_index + 1'b1;
                            state      <= ST_WAVE_REQ;
                        end
                    end
                end

                ST_SUMMARY: begin
                    if (fire_word) begin
                        if (summary_index == (SUMMARY_WORDS - 1)) begin
                            if (PADDING_WORDS > 0) begin
                                padding_index <= 32'd0;
                                state         <= ST_PADDING;
                            end else begin
                                footer_index <= 32'd0;
                                state        <= ST_FOOTER;
                            end
                        end else begin
                            summary_index <= summary_index + 1'b1;
                        end
                    end
                end

                ST_PADDING: begin
                    if (fire_word) begin
                        if (padding_index == (PADDING_WORDS - 1)) begin
                            footer_index <= 32'd0;
                            state        <= ST_FOOTER;
                        end else begin
                            padding_index <= padding_index + 1'b1;
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
