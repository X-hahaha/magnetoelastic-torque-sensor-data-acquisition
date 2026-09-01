`timescale 1ns / 1ps
/*
 * adc9268_config.v
 * AD9268 write-only SPI initialization.
 * Important: register 0x0B is shadowed; write 0x0B first, then write 0xFF=0x01 transfer.
 */
module adc9268_config(
    input  wire clk_1p25m,
    input  wire rst_n,
    output wire adc_csb,
    output wire adc_sclk,
    inout  wire adc_sdio,
    output reg  config_done
);

    localparam integer NUM_WRITES = 9;

    reg [3:0]  index;
    reg        spi_start;
    reg [23:0] spi_data;
    wire       spi_busy;
    wire       spi_done;
    wire       sdio_out;

    assign adc_sdio = sdio_out;

    spi_write24 u_spi_write24 (
        .clk    (clk_1p25m),
        .rst_n  (rst_n),
        .start  (spi_start),
        .data_i (spi_data),
        .busy   (spi_busy),
        .done   (spi_done),
        .csb    (adc_csb),
        .sclk   (adc_sclk),
        .sdio   (sdio_out)
    );

    function [23:0] cfg_word;
        input [3:0] i;
        begin
            case(i)
                4'd0: cfg_word = {16'h0014, 8'h01}; // output format: twos complement
                4'd1: cfg_word = {16'h0014, 8'h01}; // keep same as original project
                4'd2: cfg_word = {16'h0030, 8'h10}; // dither enable
                4'd3: cfg_word = {16'h000D, 8'h00}; // output test mode off
                4'd4: cfg_word = {16'h0008, 8'h80}; // normal power mode/default
                4'd5: cfg_word = {16'h0005, 8'h03}; // channel A and B selected
                4'd6: cfg_word = {16'h0017, 8'h1C}; // DCO output delay, from original project
                4'd7: cfg_word = {16'h000B, 8'h07}; // clock divide by 8: 125 MHz / 8 = 15.625 MSPS
                4'd8: cfg_word = {16'h00FF, 8'h01}; // transfer shadow registers
                default: cfg_word = 24'h000000;
            endcase
        end
    endfunction

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_WAIT = 2'd1;
    localparam [1:0] ST_DONE = 2'd2;

    reg [1:0] state;

    always @(posedge clk_1p25m or negedge rst_n) begin
        if(!rst_n) begin
            state       <= ST_IDLE;
            index       <= 4'd0;
            spi_start   <= 1'b0;
            spi_data    <= 24'd0;
            config_done <= 1'b0;
        end else begin
            spi_start <= 1'b0;

            case(state)
                ST_IDLE: begin
                    config_done <= 1'b0;
                    if(!spi_busy) begin
                        spi_data  <= cfg_word(index);
                        spi_start <= 1'b1;
                        state     <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if(spi_done) begin
                        if(index == NUM_WRITES - 1) begin
                            state       <= ST_DONE;
                            config_done <= 1'b1;
                        end else begin
                            index <= index + 1'b1;
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_DONE: begin
                    config_done <= 1'b1;
                    state       <= ST_DONE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
