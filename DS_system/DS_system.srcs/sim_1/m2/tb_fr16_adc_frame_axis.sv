`timescale 1ns / 1ps
/* Vivado behavioral testbench for the M2 frame packer. Not added as the project
 * simulation top automatically; select tb_fr16_adc_frame_axis when running it. */
module tb_fr16_adc_frame_axis;
    localparam integer SAMPLE_COUNT = 1562;
    localparam integer FRAME_WORDS = 2048;
    localparam integer SUMMARY_WORD = 6504 / 4;
    localparam integer FOOTER_WORD = 8152 / 4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg enable = 1'b1;
    reg capture_done_pulse = 1'b0;
    reg [31:0] capture_id = 32'd42;
    reg completed_bank = 1'b0;
    reg [31:0] rd_data = 32'd0;
    reg tready = 1'b1;
    wire rd_en;
    wire [11:0] rd_addr;
    wire rd_bank;
    wire [31:0] tdata;
    wire [3:0] tkeep;
    wire tvalid;
    wire tlast;
    wire active;
    wire [31:0] last_id;
    wire [31:0] overrun_count;
    wire [31:0] backpressure_count;
    wire [31:0] completed_count;

    reg [31:0] bram [0:SAMPLE_COUNT-1];
    reg [31:0] output_words [0:FRAME_WORDS-1];
    integer i;
    integer out_count = 0;
    integer timeout_cycles = 0;

    always #10 clk = ~clk;

    always @(posedge clk) begin
        if (rd_en)
            rd_data <= bram[rd_addr];
    end

    always @(posedge clk) begin
        if (tvalid && tready) begin
            output_words[out_count] <= tdata;
            out_count <= out_count + 1;
            if (tlast) begin
                #1;
                if (out_count != FRAME_WORDS) $fatal(1, "word count %0d", out_count);
                if (output_words[0] != 32'h36315246) $fatal(1, "bad header magic");
                if (output_words[1] != 32'h01000001) $fatal(1, "bad header size/version");
                if (output_words[4] != 32'd42) $fatal(1, "bad frame id");
                for (i = 0; i < SAMPLE_COUNT; i = i + 1)
                    if (output_words[64+i] != bram[i]) $fatal(1, "wave mismatch at %0d", i);
                if (output_words[SUMMARY_WORD] != 32'd1561) $fatal(1, "bad A pp");
                if (output_words[SUMMARY_WORD+1] != 32'd1561) $fatal(1, "bad B pp");
                if (output_words[FOOTER_WORD] != 32'h454E4F44) $fatal(1, "bad footer magic");
                if (output_words[FOOTER_WORD+1] != 32'd42) $fatal(1, "bad footer id");
                if (completed_count != 32'd1) $fatal(1, "completion count");
                $display("PASS: M2 packer emitted %0d words", out_count);
                $finish;
            end
        end
    end

    always @(posedge clk) begin
        timeout_cycles <= timeout_cycles + 1;
        if (timeout_cycles > 20000) $fatal(1, "timeout");
    end

    initial begin
        for (i = 0; i < SAMPLE_COUNT; i = i + 1) begin
            bram[i][15:0]  = i - 781;
            bram[i][31:16] = 1000 - i;
        end
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        repeat (3) @(posedge clk);
        capture_done_pulse <= 1'b1;
        @(posedge clk);
        capture_done_pulse <= 1'b0;
    end

    fr16_adc_frame_axis dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .capture_done_pulse(capture_done_pulse), .period_overrun_pulse(1'b0),
        .capture_id(capture_id),
        .completed_bank(completed_bank),
        .adc_a_raw_pp(32'd1561), .adc_b_raw_pp(32'd1561),
        .adc_a_filt_pp(32'd1500), .adc_b_filt_pp(32'd1500),
        .laser1_um(32'sd1), .laser2_um(32'sd2), .laser3_um(32'sd3),
        .laser4_um(32'sd4), .laser5_um(32'sd5), .temperature_x10(16'sd250),
        .sensor_valid_seen(6'h3F), .sensor_busy(6'd0),
        .sensor_crc_error(6'd0), .sensor_timeout_error(6'd0),
        .sensor_frame_error(6'd0), .adc_overrange(2'd0),
        .adc_rd_en(rd_en), .adc_rd_addr(rd_addr), .adc_rd_bank(rd_bank),
        .adc_rd_data_pair(rd_data),
        .m_axis_tdata(tdata), .m_axis_tkeep(tkeep), .m_axis_tvalid(tvalid),
        .m_axis_tready(tready), .m_axis_tlast(tlast), .active(active),
        .last_completed_frame_id(last_id), .frame_overrun_count(overrun_count),
        .axis_backpressure_count(backpressure_count),
        .completed_frame_count(completed_count)
    );
endmodule
