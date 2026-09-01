`timescale 1ns / 1ps
/*
 * modbus_rtu_master_uart.v
 * Small UART/RS-485 Modbus RTU transaction engine.
 * Sends tx_len bytes, then receives expected_rx_len bytes.
 *
 * tx_frame packing:
 *   First byte sent is tx_frame[MAX_TX_BYTES*8-1 -: 8].
 * rx_frame packing after done:
 *   The received bytes occupy the lowest rx_len bytes in correct order.
 */
module modbus_rtu_master_uart #(
    parameter integer CLK_FREQ_HZ    = 50_000_000,
    parameter integer BAUD_RATE      = 9600,
    parameter integer MAX_TX_BYTES   = 16,
    parameter integer MAX_RX_BYTES   = 16,
    parameter integer RX_TIMEOUT_MS  = 80,
    parameter integer TURNAROUND_US  = 200
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         uart_rx,
    output wire                         uart_tx,

    input  wire                         start,
    input  wire [MAX_TX_BYTES*8-1:0]    tx_frame,
    input  wire [4:0]                   tx_len,
    input  wire [4:0]                   expected_rx_len,

    output reg  [MAX_RX_BYTES*8-1:0]    rx_frame,
    output reg  [4:0]                   rx_len,
    output reg                          busy,
    output reg                          done,
    output reg                          timeout,
    output reg                          framing_error
);

    localparam integer RX_TIMEOUT_CLKS = (CLK_FREQ_HZ / 1000) * RX_TIMEOUT_MS;
    localparam integer TURNAROUND_CLKS = (CLK_FREQ_HZ / 1_000_000) * TURNAROUND_US;

    localparam [2:0] ST_IDLE       = 3'd0;
    localparam [2:0] ST_TX_LOAD    = 3'd1;
    localparam [2:0] ST_TX_WAIT    = 3'd2;
    localparam [2:0] ST_TURNAROUND = 3'd3;
    localparam [2:0] ST_RX_WAIT    = 3'd4;
    localparam [2:0] ST_DONE       = 3'd5;
    localparam [2:0] ST_TIMEOUT    = 3'd6;

    reg [2:0]  state;
    reg [31:0] timer_cnt;
    reg [4:0]  tx_index;

    reg  [7:0] tx_byte;
    reg        tx_send;
    wire       tx_done;
    wire       tx_busy;

    wire [7:0] rx_byte;
    wire       rx_done;
    wire       rx_framing_error;
    wire       rx_busy;

    // RX is disabled during TX and turnaround to avoid local echo from auto-direction RS485 modules.
    wire rx_gate = (state == ST_RX_WAIT);
    wire uart_rx_to_core = rx_gate ? uart_rx : 1'b1;

    uart_tx_byte #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_uart_tx_byte (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_byte (tx_byte),
        .send_en   (tx_send),
        .uart_tx   (uart_tx),
        .tx_done   (tx_done),
        .busy      (tx_busy)
    );

    uart_rx_byte #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_uart_rx_byte (
        .clk           (clk),
        .rst_n         (rst_n),
        .uart_rx       (uart_rx_to_core),
        .data_byte     (rx_byte),
        .rx_done       (rx_done),
        .framing_error (rx_framing_error),
        .busy          (rx_busy)
    );

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state         <= ST_IDLE;
            timer_cnt     <= 32'd0;
            tx_index      <= 5'd0;
            tx_byte       <= 8'd0;
            tx_send       <= 1'b0;
            rx_frame      <= {MAX_RX_BYTES*8{1'b0}};
            rx_len        <= 5'd0;
            busy          <= 1'b0;
            done          <= 1'b0;
            timeout       <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            tx_send <= 1'b0;
            done    <= 1'b0;
            timeout <= 1'b0;

            case(state)
                ST_IDLE: begin
                    busy          <= 1'b0;
                    timer_cnt     <= 32'd0;
                    tx_index      <= 5'd0;
                    rx_len        <= 5'd0;
                    framing_error <= 1'b0;

                    if(start) begin
                        busy     <= 1'b1;
                        rx_frame <= {MAX_RX_BYTES*8{1'b0}};
                        state    <= ST_TX_LOAD;
                    end
                end

                ST_TX_LOAD: begin
                    busy <= 1'b1;
                    if(tx_index < tx_len) begin
                        tx_byte <= tx_frame[(MAX_TX_BYTES*8-1) - tx_index*8 -: 8];
                        tx_send <= 1'b1;
                        state   <= ST_TX_WAIT;
                    end else begin
                        timer_cnt <= 32'd0;
                        state     <= ST_TURNAROUND;
                    end
                end

                ST_TX_WAIT: begin
                    busy <= 1'b1;
                    if(tx_done) begin
                        tx_index <= tx_index + 1'b1;
                        state    <= ST_TX_LOAD;
                    end
                end

                ST_TURNAROUND: begin
                    busy <= 1'b1;
                    if(expected_rx_len == 0) begin
                        state <= ST_DONE;
                    end else if(timer_cnt >= TURNAROUND_CLKS) begin
                        timer_cnt <= 32'd0;
                        rx_len    <= 5'd0;
                        state     <= ST_RX_WAIT;
                    end else begin
                        timer_cnt <= timer_cnt + 1'b1;
                    end
                end

                ST_RX_WAIT: begin
                    busy <= 1'b1;
                    if(rx_done) begin
                        rx_frame  <= {rx_frame[MAX_RX_BYTES*8-9:0], rx_byte};
                        rx_len    <= rx_len + 1'b1;
                        timer_cnt <= 32'd0;

                        if(rx_framing_error)
                            framing_error <= 1'b1;

                        if((rx_len + 1'b1) >= expected_rx_len)
                            state <= ST_DONE;
                    end else if(timer_cnt >= RX_TIMEOUT_CLKS) begin
                        state <= ST_TIMEOUT;
                    end else begin
                        timer_cnt <= timer_cnt + 1'b1;
                    end
                end

                ST_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                ST_TIMEOUT: begin
                    busy    <= 1'b0;
                    timeout <= 1'b1;
                    state   <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
