`timescale 1ns / 1ps
/*
 * temperature_modbus_reader.v
 * Reads one SA R4D RS485 infrared thermometer.
 *
 * Protocol from the manual:
 *   9600 bps, 8N1, Modbus RTU, default address 0x01.
 *   Read temperature command: 01 03 00 00 00 01 CRC_L CRC_H
 *   Response:                 01 03 02 T_HI T_LO CRC_L CRC_H
 *   Temperature data is signed 16-bit integer, unit = 0.1 deg C.
 */
module temperature_modbus_reader #(
    parameter integer CLK_FREQ_HZ       = 50_000_000,
    parameter integer BAUD_RATE         = 9600,
    parameter integer POLL_INTERVAL_MS  = 200,
    parameter integer RX_TIMEOUT_MS     = 300,
    parameter [7:0]   SLAVE_ADDR        = 8'h01
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       rs485_txd_from_module,
    output wire       rs485_rxd_to_module,

    output reg signed [15:0] temperature_x10,
    output reg               temperature_valid,
    output reg               crc_error,
    output reg               timeout_error,
    output reg               frame_error,

    output wire              modbus_busy,
    output reg [55:0]        rx_frame_dbg
);

    localparam integer MAX_TX_BYTES = 16;
    localparam integer MAX_RX_BYTES = 16;
    localparam integer POLL_CLKS = (CLK_FREQ_HZ / 1000) * POLL_INTERVAL_MS;

    wire [15:0] crc_read_cmd;
    wire [MAX_TX_BYTES*8-1:0] tx_frame;

    assign tx_frame = {
        SLAVE_ADDR, 8'h03, 8'h00, 8'h00, 8'h00, 8'h01, crc_read_cmd[7:0], crc_read_cmd[15:8],
        64'h0000_0000_0000_0000
    };

    wire [15:0] cmd_c1 = crc16_update(16'hFFFF, SLAVE_ADDR);
    wire [15:0] cmd_c2 = crc16_update(cmd_c1,    8'h03);
    wire [15:0] cmd_c3 = crc16_update(cmd_c2,    8'h00);
    wire [15:0] cmd_c4 = crc16_update(cmd_c3,    8'h00);
    wire [15:0] cmd_c5 = crc16_update(cmd_c4,    8'h00);
    wire [15:0] cmd_c6 = crc16_update(cmd_c5,    8'h01);
    assign crc_read_cmd = cmd_c6;

    reg        trans_start;
    wire       trans_done;
    wire       trans_timeout;
    wire       trans_framing_error;
    wire [MAX_RX_BYTES*8-1:0] rx_frame_full;
    wire [4:0] rx_len;

    modbus_rtu_master_uart #(
        .CLK_FREQ_HZ   (CLK_FREQ_HZ),
        .BAUD_RATE     (BAUD_RATE),
        .MAX_TX_BYTES  (MAX_TX_BYTES),
        .MAX_RX_BYTES  (MAX_RX_BYTES),
        .RX_TIMEOUT_MS (RX_TIMEOUT_MS),
        .TURNAROUND_US (200)
    ) u_modbus (
        .clk             (clk),
        .rst_n           (rst_n),
        .uart_rx         (rs485_txd_from_module),
        .uart_tx         (rs485_rxd_to_module),
        .start           (trans_start),
        .tx_frame        (tx_frame),
        .tx_len          (5'd8),
        .expected_rx_len (5'd7),
        .rx_frame        (rx_frame_full),
        .rx_len          (rx_len),
        .busy            (modbus_busy),
        .done            (trans_done),
        .timeout         (trans_timeout),
        .framing_error   (trans_framing_error)
    );

    wire [55:0] rx7 = rx_frame_full[55:0];

    wire [7:0] b0 = rx7[55:48];
    wire [7:0] b1 = rx7[47:40];
    wire [7:0] b2 = rx7[39:32];
    wire [7:0] b3 = rx7[31:24];
    wire [7:0] b4 = rx7[23:16];
    wire [7:0] b5 = rx7[15:8];
    wire [7:0] b6 = rx7[7:0];

    wire [15:0] resp_crc;
    wire [15:0] r_c1 = crc16_update(16'hFFFF, b0);
    wire [15:0] r_c2 = crc16_update(r_c1,     b1);
    wire [15:0] r_c3 = crc16_update(r_c2,     b2);
    wire [15:0] r_c4 = crc16_update(r_c3,     b3);
    wire [15:0] r_c5 = crc16_update(r_c4,     b4);
    assign resp_crc = r_c5;

    wire crc_ok   = (b5 == resp_crc[7:0]) && (b6 == resp_crc[15:8]);
    wire frame_ok = (rx_len == 5'd7) && (b0 == SLAVE_ADDR) && (b1 == 8'h03) && (b2 == 8'h02) && crc_ok;

    wire signed [15:0] temp_parsed_x10 = $signed({b3, b4});

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

    localparam [1:0] ST_START = 2'd0;
    localparam [1:0] ST_WAIT  = 2'd1;
    localparam [1:0] ST_GAP   = 2'd2;

    reg [1:0] state;
    reg [31:0] poll_cnt;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state             <= ST_START;
            poll_cnt          <= 32'd0;
            trans_start       <= 1'b0;
            temperature_x10   <= 16'sd0;
            temperature_valid <= 1'b0;
            crc_error         <= 1'b0;
            timeout_error     <= 1'b0;
            frame_error       <= 1'b0;
            rx_frame_dbg      <= 56'd0;
        end else begin
            trans_start       <= 1'b0;
            temperature_valid <= 1'b0;

            case(state)
                ST_START: begin
                    crc_error     <= 1'b0;
                    timeout_error <= 1'b0;
                    frame_error   <= 1'b0;
                    trans_start   <= 1'b1;
                    poll_cnt      <= 32'd0;
                    state         <= ST_WAIT;
                end

                ST_WAIT: begin
                    if(trans_done) begin
                        rx_frame_dbg <= rx7;
                        if(frame_ok) begin
                            temperature_x10   <= temp_parsed_x10;
                            temperature_valid <= 1'b1;
                            crc_error         <= 1'b0;
                            frame_error       <= 1'b0;
                        end else begin
                            if(!crc_ok)
                                crc_error <= 1'b1;
                            else
                                frame_error <= 1'b1;
                        end
                        state    <= ST_GAP;
                        poll_cnt <= 32'd0;
                    end else if(trans_timeout) begin
                        timeout_error <= 1'b1;
                        state         <= ST_GAP;
                        poll_cnt      <= 32'd0;
                    end else if(trans_framing_error) begin
                        frame_error <= 1'b1;
                    end
                end

                ST_GAP: begin
                    if(poll_cnt >= POLL_CLKS) begin
                        poll_cnt <= 32'd0;
                        state    <= ST_START;
                    end else begin
                        poll_cnt <= poll_cnt + 1'b1;
                    end
                end

                default: state <= ST_START;
            endcase
        end
    end

endmodule
