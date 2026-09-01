`timescale 1ns / 1ps
/*
 * debug_readout_sequencer.v
 * After capture_done_pulse, automatically reads metadata and ADC pair memory once.
 * This is only for PL verification with ILA/mark_debug signals.
 */
module debug_readout_sequencer #(
    parameter integer SAMPLE_COUNT = 3125,
    parameter integer ADDR_WIDTH   = 12
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  capture_done_pulse,

    output reg                   rd_en,
    output reg  [1:0]            rd_sel,
    output reg  [ADDR_WIDTH-1:0] rd_addr,
    input  wire [31:0]           rd_data,

    output reg                   readout_active,
    output reg                   readout_done
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_META = 2'd1;
    localparam [1:0] ST_ADC  = 2'd2;
    localparam [1:0] ST_DONE = 2'd3;

    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state          <= ST_IDLE;
            rd_en          <= 1'b0;
            rd_sel         <= 2'd0;
            rd_addr        <= {ADDR_WIDTH{1'b0}};
            readout_active <= 1'b0;
            readout_done   <= 1'b0;
        end else begin
            rd_en        <= 1'b0;
            readout_done <= 1'b0;

            case(state)
                ST_IDLE: begin
                    readout_active <= 1'b0;
                    if(capture_done_pulse) begin
                        readout_active <= 1'b1;
                        rd_sel         <= 2'd0;
                        rd_addr        <= {ADDR_WIDTH{1'b0}};
                        state          <= ST_META;
                    end
                end

                ST_META: begin
                    readout_active <= 1'b1;
                    rd_en          <= 1'b1;
                    rd_sel         <= 2'd0;

                    if(rd_addr == 12'd14) begin
                        rd_addr <= {ADDR_WIDTH{1'b0}};
                        state   <= ST_ADC;
                    end else begin
                        rd_addr <= rd_addr + 1'b1;
                    end
                end

                ST_ADC: begin
                    readout_active <= 1'b1;
                    rd_en          <= 1'b1;
                    rd_sel         <= 2'd3;

                    if(rd_addr == SAMPLE_COUNT - 1) begin
                        rd_addr <= {ADDR_WIDTH{1'b0}};
                        state   <= ST_DONE;
                    end else begin
                        rd_addr <= rd_addr + 1'b1;
                    end
                end

                ST_DONE: begin
                    readout_active <= 1'b0;
                    readout_done   <= 1'b1;
                    state          <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
