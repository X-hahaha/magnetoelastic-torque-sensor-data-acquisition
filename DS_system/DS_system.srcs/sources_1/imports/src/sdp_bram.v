`timescale 1ns / 1ps
/*
 * sdp_bram.v
 * Simple dual-port block RAM inference: one write port, one read port.
 * Read data has one-clock latency after rd_en.
 */
module sdp_bram #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ADDR_WIDTH = 12
)(
    input  wire                     wr_clk,
    input  wire                     wr_en,
    input  wire [ADDR_WIDTH-1:0]    wr_addr,
    input  wire [DATA_WIDTH-1:0]    wr_data,

    input  wire                     rd_clk,
    input  wire                     rd_en,
    input  wire [ADDR_WIDTH-1:0]    rd_addr,
    output reg  [DATA_WIDTH-1:0]    rd_data
);

    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    always @(posedge wr_clk) begin
        if(wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        if(rd_en)
            rd_data <= mem[rd_addr];
    end

endmodule
