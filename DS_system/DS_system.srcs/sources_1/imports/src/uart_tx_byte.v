`timescale 1ns / 1ps
/*
 * uart_tx_byte.v
 * Simple UART transmitter, 8N1, LSB first.
 */
module uart_tx_byte #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BAUD_RATE   = 9600
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] data_byte,
    input  wire       send_en,

    output reg        uart_tx,
    output reg        tx_done,
    output reg        busy
);

    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA  = 2'd2;
    localparam [1:0] ST_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  data_reg;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state     <= ST_IDLE;
            clk_cnt   <= 32'd0;
            bit_idx   <= 3'd0;
            data_reg  <= 8'd0;
            uart_tx   <= 1'b1;
            tx_done   <= 1'b0;
            busy      <= 1'b0;
        end else begin
            tx_done <= 1'b0;

            case(state)
                ST_IDLE: begin
                    uart_tx <= 1'b1;
                    busy    <= 1'b0;
                    clk_cnt <= 32'd0;
                    bit_idx <= 3'd0;

                    if(send_en) begin
                        data_reg <= data_byte;
                        busy     <= 1'b1;
                        state    <= ST_START;
                    end
                end

                ST_START: begin
                    uart_tx <= 1'b0;
                    busy    <= 1'b1;

                    if(clk_cnt >= CLKS_PER_BIT - 1) begin
                        clk_cnt <= 32'd0;
                        state   <= ST_DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_DATA: begin
                    uart_tx <= data_reg[bit_idx];
                    busy    <= 1'b1;

                    if(clk_cnt >= CLKS_PER_BIT - 1) begin
                        clk_cnt <= 32'd0;
                        if(bit_idx == 3'd7) begin
                            bit_idx <= 3'd0;
                            state   <= ST_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_STOP: begin
                    uart_tx <= 1'b1;
                    busy    <= 1'b1;

                    if(clk_cnt >= CLKS_PER_BIT - 1) begin
                        clk_cnt <= 32'd0;
                        tx_done <= 1'b1;
                        state   <= ST_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
