`timescale 1ns / 1ps
/*
 * rs485_sensors_reader.v
 * Background polling for 5 independent PDL laser sensors and 1 independent temperature sensor.
 *
 * Laser side:
 *   - Configures each PDL sensor at power-up: cancel zero + absolute-distance output.
 *   - Runs at 468800 bps (sensor pre-configured; no baud-change command is sent)
 *     with a 700 us poll period per channel, so each laser updates at ~1.4 kHz.
 *
 * Temperature side:
 *   - Kept at the manual/default 9600 bps. No baud-rate configuration command is sent.
 */
module rs485_sensors_reader #(
    parameter integer CLK_FREQ_HZ       = 50_000_000,
    parameter integer LASER_INIT_BAUD   = 9600,
    parameter integer LASER_BAUD_RATE   = 9600,
    parameter integer TEMP_BAUD_RATE    = 9600,
    parameter [7:0]   SENSOR_ADDR       = 8'h01
)(
    input  wire clk,
    input  wire rst_n,

    input  wire TXD_LAYSER1,
    output wire RXD_LAYSER1,
    input  wire TXD_LAYSER2,
    output wire RXD_LAYSER2,
    input  wire TXD_LAYSER3,
    output wire RXD_LAYSER3,
    input  wire TXD_LAYSER4,
    output wire RXD_LAYSER4,
    input  wire TXD_LAYSER5,
    output wire RXD_LAYSER5,

    input  wire TXD_TEMPERATURE,
    output wire RXD_TEMPERATURE,

    output wire signed [31:0] laser1_distance_um,
    output wire signed [31:0] laser2_distance_um,
    output wire signed [31:0] laser3_distance_um,
    output wire signed [31:0] laser4_distance_um,
    output wire signed [31:0] laser5_distance_um,
    output wire signed [15:0] temperature_x10,

    output wire [5:0] valid_pulse,
    output reg  [5:0] valid_seen,
    output wire [5:0] busy,
    output wire [5:0] crc_error,
    output wire [5:0] timeout_error,
    output wire [5:0] frame_error
);

    wire [71:0] laser_rx_dbg1;
    wire [71:0] laser_rx_dbg2;
    wire [71:0] laser_rx_dbg3;
    wire [71:0] laser_rx_dbg4;
    wire [71:0] laser_rx_dbg5;
    wire [55:0] temp_rx_dbg;

    wire laser1_config_done, laser1_config_error;
    wire laser2_config_done, laser2_config_error;
    wire laser3_config_done, laser3_config_error;
    wire laser4_config_done, laser4_config_error;
    wire laser5_config_done, laser5_config_error;

    pdl030_config_distance_reader #(
        .CLK_FREQ_HZ      (CLK_FREQ_HZ),
        .INIT_BAUD_RATE   (LASER_INIT_BAUD),
        .LASER_BAUD_RATE  (LASER_BAUD_RATE),
        .POLL_PERIOD_US  (700),
        .RX_TIMEOUT_MS    (80),
        .WORD_SWAP        (1),
        .SLAVE_ADDR       (SENSOR_ADDR)
    ) u_laser1 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .rs485_txd_from_module (TXD_LAYSER1),
        .rs485_rxd_to_module   (RXD_LAYSER1),
        .distance_um           (laser1_distance_um),
        .distance_valid        (valid_pulse[0]),
        .crc_error             (crc_error[0]),
        .timeout_error         (timeout_error[0]),
        .frame_error           (frame_error[0]),
        .modbus_busy           (busy[0]),
        .config_done           (laser1_config_done),
        .config_error          (laser1_config_error),
        .rx_frame_dbg          (laser_rx_dbg1)
    );

    pdl030_config_distance_reader #(
        .CLK_FREQ_HZ      (CLK_FREQ_HZ),
        .INIT_BAUD_RATE   (LASER_INIT_BAUD),
        .LASER_BAUD_RATE  (LASER_BAUD_RATE),
        .POLL_PERIOD_US  (700),
        .RX_TIMEOUT_MS    (80),
        .WORD_SWAP        (1),
        .SLAVE_ADDR       (SENSOR_ADDR)
    ) u_laser2 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .rs485_txd_from_module (TXD_LAYSER2),
        .rs485_rxd_to_module   (RXD_LAYSER2),
        .distance_um           (laser2_distance_um),
        .distance_valid        (valid_pulse[1]),
        .crc_error             (crc_error[1]),
        .timeout_error         (timeout_error[1]),
        .frame_error           (frame_error[1]),
        .modbus_busy           (busy[1]),
        .config_done           (laser2_config_done),
        .config_error          (laser2_config_error),
        .rx_frame_dbg          (laser_rx_dbg2)
    );

    pdl030_config_distance_reader #(
        .CLK_FREQ_HZ      (CLK_FREQ_HZ),
        .INIT_BAUD_RATE   (LASER_INIT_BAUD),
        .LASER_BAUD_RATE  (LASER_BAUD_RATE),
        .POLL_PERIOD_US  (700),
        .RX_TIMEOUT_MS    (80),
        .WORD_SWAP        (1),
        .SLAVE_ADDR       (SENSOR_ADDR)
    ) u_laser3 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .rs485_txd_from_module (TXD_LAYSER3),
        .rs485_rxd_to_module   (RXD_LAYSER3),
        .distance_um           (laser3_distance_um),
        .distance_valid        (valid_pulse[2]),
        .crc_error             (crc_error[2]),
        .timeout_error         (timeout_error[2]),
        .frame_error           (frame_error[2]),
        .modbus_busy           (busy[2]),
        .config_done           (laser3_config_done),
        .config_error          (laser3_config_error),
        .rx_frame_dbg          (laser_rx_dbg3)
    );

    pdl030_config_distance_reader #(
        .CLK_FREQ_HZ      (CLK_FREQ_HZ),
        .INIT_BAUD_RATE   (LASER_INIT_BAUD),
        .LASER_BAUD_RATE  (LASER_BAUD_RATE),
        .POLL_PERIOD_US  (700),
        .RX_TIMEOUT_MS    (80),
        .WORD_SWAP        (1),
        .SLAVE_ADDR       (SENSOR_ADDR)
    ) u_laser4 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .rs485_txd_from_module (TXD_LAYSER4),
        .rs485_rxd_to_module   (RXD_LAYSER4),
        .distance_um           (laser4_distance_um),
        .distance_valid        (valid_pulse[3]),
        .crc_error             (crc_error[3]),
        .timeout_error         (timeout_error[3]),
        .frame_error           (frame_error[3]),
        .modbus_busy           (busy[3]),
        .config_done           (laser4_config_done),
        .config_error          (laser4_config_error),
        .rx_frame_dbg          (laser_rx_dbg4)
    );

    pdl030_config_distance_reader #(
        .CLK_FREQ_HZ      (CLK_FREQ_HZ),
        .INIT_BAUD_RATE   (LASER_INIT_BAUD),
        .LASER_BAUD_RATE  (LASER_BAUD_RATE),
        .POLL_PERIOD_US  (700),
        .RX_TIMEOUT_MS    (80),
        .WORD_SWAP        (1),
        .SLAVE_ADDR       (SENSOR_ADDR)
    ) u_laser5 (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .rs485_txd_from_module (TXD_LAYSER5),
        .rs485_rxd_to_module   (RXD_LAYSER5),
        .distance_um           (laser5_distance_um),
        .distance_valid        (valid_pulse[4]),
        .crc_error             (crc_error[4]),
        .timeout_error         (timeout_error[4]),
        .frame_error           (frame_error[4]),
        .modbus_busy           (busy[4]),
        .config_done           (laser5_config_done),
        .config_error          (laser5_config_error),
        .rx_frame_dbg          (laser_rx_dbg5)
    );

    temperature_modbus_reader #(
        .CLK_FREQ_HZ      (CLK_FREQ_HZ),
        .BAUD_RATE        (TEMP_BAUD_RATE),
        .POLL_INTERVAL_MS (200),
        .RX_TIMEOUT_MS    (300),
        .SLAVE_ADDR       (SENSOR_ADDR)
    ) u_temperature (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .rs485_txd_from_module (TXD_TEMPERATURE),
        .rs485_rxd_to_module   (RXD_TEMPERATURE),
        .temperature_x10       (temperature_x10),
        .temperature_valid     (valid_pulse[5]),
        .crc_error             (crc_error[5]),
        .timeout_error         (timeout_error[5]),
        .frame_error           (frame_error[5]),
        .modbus_busy           (busy[5]),
        .rx_frame_dbg          (temp_rx_dbg)
    );

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            valid_seen <= 6'd0;
        else
            valid_seen <= valid_seen | valid_pulse;
    end

endmodule
