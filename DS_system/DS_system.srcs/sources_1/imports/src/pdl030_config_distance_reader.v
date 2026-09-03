`timescale 1ns / 1ps
/*
 * pdl030_config_distance_reader.v
 *
 * PDL-xxx-485 laser reader with power-up configuration, fixed baud.
 *
 * This version does NOT change the PDL baud rate; the sensor must already be
 * configured for LASER_BAUD_RATE (468800 bps in the current build).
 * At power-up it uses LASER_BAUD_RATE to:
 *   1) cancel zero setting;
 *   2) set output data format to absolute distance;
 *   3) continuously read the distance register.
 *
 * At 468800 bps one request/response transaction takes ~400 us (8-byte request
 * + 30 us turnaround + 9-byte response, plus sensor latency), so the 700 us
 * poll period leaves ~300 us of budget for the sensor response.
 *
 * Output distance_um is the PDL returned absolute distance value in um.
 *
 * Distance polling runs on a fixed period of POLL_PERIOD_US (default 700 us),
 * measured from the start of each request transaction. If a transaction
 * overruns the period (slow sensor response or timeout), the next request
 * starts immediately after it completes.
 */
module pdl030_config_distance_reader #(
    parameter integer CLK_FREQ_HZ       = 50_000_000,
    parameter integer INIT_BAUD_RATE    = 9600,       // kept for compatibility; not used
    parameter integer LASER_BAUD_RATE   = 9600,
    parameter integer POLL_PERIOD_US    = 700,
    parameter integer RX_TIMEOUT_MS     = 80,
    parameter integer WORD_SWAP         = 1,
    parameter [7:0]   SLAVE_ADDR        = 8'h01
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        rs485_txd_from_module, // RS485 module TXD -> FPGA RX
    output wire        rs485_rxd_to_module,   // FPGA TX -> RS485 module RXD

    output reg signed [31:0] distance_um,
    output reg               distance_valid,
    output reg               crc_error,
    output reg               timeout_error,
    output reg               frame_error,

    output wire              modbus_busy,
    output reg               config_done,
    output reg               config_error,
    output reg [71:0]        rx_frame_dbg
);

    localparam integer MAX_TX_BYTES = 16;
    localparam integer MAX_RX_BYTES = 16;
    localparam integer POLL_PERIOD_CLKS = (CLK_FREQ_HZ / 1_000_000) * POLL_PERIOD_US;

    // Register addresses from the PDL manual command table used in previous verified code.
    localparam [15:0] REG_CANCEL_ZERO = 16'h0002;
    localparam [15:0] REG_DISTANCE    = 16'h003B;
    localparam [15:0] REG_DATA_FORMAT = 16'h003D;

    localparam [15:0] VAL_CANCEL_ZERO = 16'h0000;
    localparam [15:0] VAL_ABSOLUTE    = 16'h0001;

    // -------------------------
    // CRC and frame builders
    // -------------------------
    function [15:0] crc16_update;
        input [15:0] crc_in;
        input [7:0]  data;
        integer i;
        reg [15:0] crc;
        begin
            crc = crc_in ^ data;
            for(i = 0; i < 8; i = i + 1) begin
                if(crc[0])
                    crc = (crc >> 1) ^ 16'hA001;
                else
                    crc = (crc >> 1);
            end
            crc16_update = crc;
        end
    endfunction

    function [15:0] crc6;
        input [7:0] b0;
        input [7:0] b1;
        input [7:0] b2;
        input [7:0] b3;
        input [7:0] b4;
        input [7:0] b5;
        reg [15:0] c;
        begin
            c = crc16_update(16'hFFFF, b0);
            c = crc16_update(c, b1);
            c = crc16_update(c, b2);
            c = crc16_update(c, b3);
            c = crc16_update(c, b4);
            c = crc16_update(c, b5);
            crc6 = c;
        end
    endfunction

    function [MAX_TX_BYTES*8-1:0] make_req6;
        input [7:0]  addr;
        input [7:0]  func;
        input [15:0] reg_addr;
        input [15:0] value;
        reg [15:0] c;
        begin
            c = crc6(addr, func, reg_addr[15:8], reg_addr[7:0], value[15:8], value[7:0]);
            make_req6 = {
                addr, func, reg_addr[15:8], reg_addr[7:0], value[15:8], value[7:0], c[7:0], c[15:8],
                64'h0000_0000_0000_0000
            };
        end
    endfunction

    // -------------------------
    // Modbus master at fixed laser baud rate
    // -------------------------
    reg        mb_start;
    reg [MAX_TX_BYTES*8-1:0] mb_tx_frame;
    reg [4:0]  mb_rx_expected;
    wire [MAX_RX_BYTES*8-1:0] mb_rx_frame_full;
    wire [4:0] mb_rx_len;
    wire       mb_busy;
    wire       mb_done;
    wire       mb_timeout;
    wire       mb_framing_error;

    modbus_rtu_master_uart #(
        .CLK_FREQ_HZ   (CLK_FREQ_HZ),
        .BAUD_RATE     (LASER_BAUD_RATE),
        .MAX_TX_BYTES  (MAX_TX_BYTES),
        .MAX_RX_BYTES  (MAX_RX_BYTES),
        .RX_TIMEOUT_MS (RX_TIMEOUT_MS),
        .TURNAROUND_US (30)
    ) u_modbus (
        .clk             (clk),
        .rst_n           (rst_n),
        .uart_rx         (rs485_txd_from_module),
        .uart_tx         (rs485_rxd_to_module),
        .start           (mb_start),
        .tx_frame        (mb_tx_frame),
        .tx_len          (5'd8),
        .expected_rx_len (mb_rx_expected),
        .rx_frame        (mb_rx_frame_full),
        .rx_len          (mb_rx_len),
        .busy            (mb_busy),
        .done            (mb_done),
        .timeout         (mb_timeout),
        .framing_error   (mb_framing_error)
    );

    assign modbus_busy = mb_busy;

    // -------------------------
    // Response parsing for distance read
    // -------------------------
    wire [71:0] rx9 = mb_rx_frame_full[71:0];

    wire [7:0] b0 = rx9[71:64];
    wire [7:0] b1 = rx9[63:56];
    wire [7:0] b2 = rx9[55:48];
    wire [7:0] b3 = rx9[47:40];
    wire [7:0] b4 = rx9[39:32];
    wire [7:0] b5 = rx9[31:24];
    wire [7:0] b6 = rx9[23:16];
    wire [7:0] b7 = rx9[15:8];
    wire [7:0] b8 = rx9[7:0];

    wire [15:0] resp_crc;
    wire [15:0] r_c1 = crc16_update(16'hFFFF, b0);
    wire [15:0] r_c2 = crc16_update(r_c1,     b1);
    wire [15:0] r_c3 = crc16_update(r_c2,     b2);
    wire [15:0] r_c4 = crc16_update(r_c3,     b3);
    wire [15:0] r_c5 = crc16_update(r_c4,     b4);
    wire [15:0] r_c6 = crc16_update(r_c5,     b5);
    wire [15:0] r_c7 = crc16_update(r_c6,     b6);
    assign resp_crc = r_c7;

    wire crc_ok = (b7 == resp_crc[7:0]) && (b8 == resp_crc[15:8]);
    wire frame_ok = (mb_rx_len == 5'd9) && (b0 == SLAVE_ADDR) && (b1 == 8'h03) && (b2 == 8'h04) && crc_ok;

    wire signed [31:0] distance_parsed_um;
    assign distance_parsed_um = (WORD_SWAP != 0) ? $signed({b5, b6, b3, b4}) : $signed({b3, b4, b5, b6});

    // -------------------------
    // Main state machine
    // -------------------------
    localparam [2:0] ST_CANCEL_START = 3'd0;
    localparam [2:0] ST_CANCEL_WAIT  = 3'd1;
    localparam [2:0] ST_ABS_START    = 3'd2;
    localparam [2:0] ST_ABS_WAIT     = 3'd3;
    localparam [2:0] ST_POLL_START   = 3'd4;
    localparam [2:0] ST_POLL_WAIT    = 3'd5;
    localparam [2:0] ST_POLL_GAP     = 3'd6;

    reg [2:0]  state;
    reg [31:0] timer_cnt;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state          <= ST_CANCEL_START;
            timer_cnt      <= 32'd0;
            mb_start       <= 1'b0;
            mb_tx_frame    <= {MAX_TX_BYTES*8{1'b0}};
            mb_rx_expected <= 5'd8;
            distance_um    <= 32'sd0;
            distance_valid <= 1'b0;
            crc_error      <= 1'b0;
            timeout_error  <= 1'b0;
            frame_error    <= 1'b0;
            config_done    <= 1'b0;
            config_error   <= 1'b0;
            rx_frame_dbg   <= 72'd0;
        end else begin
            mb_start       <= 1'b0;
            distance_valid <= 1'b0;

            case(state)
                ST_CANCEL_START: begin
                    mb_tx_frame <= make_req6(SLAVE_ADDR, 8'h05, REG_CANCEL_ZERO, VAL_CANCEL_ZERO);
                    mb_rx_expected <= 5'd8;
                    mb_start <= 1'b1;
                    timeout_error <= 1'b0;
                    frame_error <= 1'b0;
                    crc_error <= 1'b0;
                    state <= ST_CANCEL_WAIT;
                end

                ST_CANCEL_WAIT: begin
                    if(mb_done || mb_timeout) begin
                        if(mb_timeout) config_error <= 1'b1;
                        if(mb_framing_error) config_error <= 1'b1;
                        state <= ST_ABS_START;
                    end
                end

                ST_ABS_START: begin
                    mb_tx_frame <= make_req6(SLAVE_ADDR, 8'h06, REG_DATA_FORMAT, VAL_ABSOLUTE);
                    mb_rx_expected <= 5'd8;
                    mb_start <= 1'b1;
                    state <= ST_ABS_WAIT;
                end

                ST_ABS_WAIT: begin
                    if(mb_done || mb_timeout) begin
                        if(mb_timeout) config_error <= 1'b1;
                        if(mb_framing_error) config_error <= 1'b1;
                        config_done <= 1'b1;
                        state <= ST_POLL_START;
                    end
                end

                ST_POLL_START: begin
                    mb_tx_frame <= make_req6(SLAVE_ADDR, 8'h03, REG_DISTANCE, 16'h0002);
                    mb_rx_expected <= 5'd9;
                    mb_start <= 1'b1;
                    timeout_error <= 1'b0;
                    frame_error <= 1'b0;
                    crc_error <= 1'b0;
                    timer_cnt <= 32'd0;
                    state <= ST_POLL_WAIT;
                end

                ST_POLL_WAIT: begin
                    timer_cnt <= timer_cnt + 1'b1;
                    if(mb_done) begin
                        rx_frame_dbg <= rx9;
                        if(frame_ok) begin
                            distance_um    <= distance_parsed_um;
                            distance_valid <= 1'b1;
                            crc_error      <= 1'b0;
                            frame_error    <= 1'b0;
                            timeout_error  <= 1'b0;
                        end else begin
                            if(!crc_ok)
                                crc_error <= 1'b1;
                            else
                                frame_error <= 1'b1;
                        end
                        state <= ST_POLL_GAP;
                    end else if(mb_timeout) begin
                        timeout_error <= 1'b1;
                        state <= ST_POLL_GAP;
                    end else if(mb_framing_error) begin
                        frame_error <= 1'b1;
                    end
                end

                ST_POLL_GAP: begin
                    if(timer_cnt >= POLL_PERIOD_CLKS) begin
                        state <= ST_POLL_START;
                    end else begin
                        timer_cnt <= timer_cnt + 1'b1;
                    end
                end

                default: state <= ST_CANCEL_START;
            endcase
        end
    end

endmodule
