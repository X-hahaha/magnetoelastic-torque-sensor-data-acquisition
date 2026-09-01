`timescale 1ns / 1ps
/*
 * spi_write24.v
 * Write-only 24-bit SPI shifter for AD9268 3-wire SPI writes.
 * SCLK idles low. SDIO changes while SCLK is low and is stable before each rising edge.
 */
module spi_write24(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [23:0] data_i,
    output reg         busy,
    output reg         done,
    output reg         csb,
    output reg         sclk,
    output reg         sdio
);

    reg [23:0] shreg;
    reg [4:0]  bit_cnt;
    reg        phase;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            busy    <= 1'b0;
            done    <= 1'b0;
            csb     <= 1'b1;
            sclk    <= 1'b0;
            sdio    <= 1'b0;
            shreg   <= 24'd0;
            bit_cnt <= 5'd0;
            phase   <= 1'b0;
        end else begin
            done <= 1'b0;

            if(!busy) begin
                csb  <= 1'b1;
                sclk <= 1'b0;
                phase <= 1'b0;

                if(start) begin
                    busy    <= 1'b1;
                    csb     <= 1'b0;
                    sclk    <= 1'b0;
                    shreg   <= data_i;
                    bit_cnt <= 5'd23;
                    sdio    <= data_i[23];
                    phase   <= 1'b0;
                end
            end else begin
                if(phase == 1'b0) begin
                    sclk  <= 1'b1;
                    phase <= 1'b1;
                end else begin
                    sclk <= 1'b0;
                    if(bit_cnt == 5'd0) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        csb   <= 1'b1;
                        sdio  <= 1'b0;
                    end else begin
                        bit_cnt <= bit_cnt - 1'b1;
                        shreg   <= {shreg[22:0], 1'b0};
                        sdio    <= shreg[22];
                        phase   <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
