`timescale 1ns / 1ps
/*
 * uart_rx_byte.v
 * Simple UART receiver, 8N1, LSB first.
 */
module uart_rx_byte #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BAUD_RATE   = 9600
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       uart_rx,

    output reg [7:0]  data_byte,
    output reg        rx_done,
    output reg        framing_error,
    output reg        busy
);

    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA  = 2'd2;
    localparam [1:0] ST_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  data_reg;

    reg rx_sync1;
    reg rx_sync2;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= uart_rx;
            rx_sync2 <= rx_sync1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state         <= ST_IDLE;
            clk_cnt       <= 32'd0;
            bit_idx       <= 3'd0;
            data_reg      <= 8'd0;
            data_byte     <= 8'd0;
            rx_done       <= 1'b0;
            framing_error <= 1'b0;
            busy          <= 1'b0;
        end else begin
            rx_done <= 1'b0;

            case(state)
                ST_IDLE: begin
                    busy          <= 1'b0;
                    clk_cnt       <= 32'd0;
                    bit_idx       <= 3'd0;
                    framing_error <= 1'b0;

                    if(rx_sync2 == 1'b0) begin
                        busy  <= 1'b1;
                        state <= ST_START;
                    end
                end

                ST_START: begin
                    busy <= 1'b1;

                    if(clk_cnt >= HALF_BIT - 1) begin
                        clk_cnt <= 32'd0;
                        if(rx_sync2 == 1'b0) begin
                            state <= ST_DATA;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_DATA: begin
                    busy <= 1'b1;

                    if(clk_cnt >= CLKS_PER_BIT - 1) begin
                        clk_cnt <= 32'd0;
                        data_reg[bit_idx] <= rx_sync2;

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
                    busy <= 1'b1;

                    if(clk_cnt >= CLKS_PER_BIT - 1) begin
                        clk_cnt   <= 32'd0;
                        data_byte <= data_reg;
                        rx_done   <= 1'b1;

                        if(rx_sync2 != 1'b1)
                            framing_error <= 1'b1;

                        state <= ST_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
