`timescale 1ns / 1ps
/*
 * clk_div_125m_to_1p25m.v
 * Divides 125 MHz to 1.25 MHz square wave.
 */
module clk_div_125m_to_1p25m(
    input  wire clk_125m,
    input  wire rst_n,
    output reg  clk_1p25m
);

    reg [7:0] cnt;

    always @(posedge clk_125m or negedge rst_n) begin
        if(!rst_n) begin
            cnt       <= 8'd0;
            clk_1p25m <= 1'b0;
        end else begin
            if(cnt >= 8'd49) begin
                cnt       <= 8'd0;
                clk_1p25m <= ~clk_1p25m;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
