`timescale 1ns / 1ps
/*
 * cdc_pulse_sync.v
 * Transfers a one-clock pulse from source clock domain to destination clock domain.
 */
module cdc_pulse_sync(
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,

    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire dst_pulse
);

    reg src_toggle;
    always @(posedge src_clk or negedge src_rst_n) begin
        if(!src_rst_n)
            src_toggle <= 1'b0;
        else if(src_pulse)
            src_toggle <= ~src_toggle;
    end

    reg dst_sync1;
    reg dst_sync2;
    reg dst_sync3;

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if(!dst_rst_n) begin
            dst_sync1 <= 1'b0;
            dst_sync2 <= 1'b0;
            dst_sync3 <= 1'b0;
        end else begin
            dst_sync1 <= src_toggle;
            dst_sync2 <= dst_sync1;
            dst_sync3 <= dst_sync2;
        end
    end

    assign dst_pulse = dst_sync2 ^ dst_sync3;

endmodule
