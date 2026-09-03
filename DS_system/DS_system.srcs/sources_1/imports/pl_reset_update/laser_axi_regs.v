`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// AXI-Lite register block for sensor/ADC summary + host capture trigger + PL soft reset hold.
//
// Long-frame capture command:
//   0x38 write 0xCACE0001: emit one capture_start pulse to pl_capture_logic.
//   0x38 read : command/status scratch.
//   0x3C read : PL debug status from pl_capture_logic.
//
// Runtime waveform length:
//   0x24 read/write: sample_count_cfg in samples per channel. Reset default is
//   DEFAULT_SAMPLE_COUNT (manual long frame). PS shortens it for auto mode.
//   Writes outside [MIN_SAMPLE_COUNT, DEFAULT_SAMPLE_COUNT] are ignored.
//   Change only while no capture is active; the frame packer latches the value
//   at capture start.
//
// The ADC BRAM read port is driven by adc_sample_rd_en/addr, and the returned
// adc_sample_rd_data is latched internally after a few S_AXI_ACLK cycles.
//
// PL reset hold control:
//   write 0xA55A0001 to 0x00: assert pl_soft_reset_hold
//   write 0x00000000 to 0x00: deassert pl_soft_reset_hold
// M1 DMA note: reset default is asserted so the AXIS FIFO/FR16 test stream
// cannot fill before PS has configured AXI DMA S2MM SG descriptors.
// The AXI-Lite register block itself is not reset by this signal, so PS can release PL reset.
//////////////////////////////////////////////////////////////////////////////////

module laser_axi_regs #(
    parameter integer C_S_AXI_ADDR_WIDTH = 6,
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer ADC_ADDR_WIDTH     = 12
)(
    input  wire                              S_AXI_ACLK,
    input  wire                              S_AXI_ARESETN,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_AWADDR,
    input  wire                              S_AXI_AWVALID,
    output reg                               S_AXI_AWREADY,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
    input  wire                              S_AXI_WVALID,
    output reg                               S_AXI_WREADY,

    output reg  [1:0]                        S_AXI_BRESP,
    output reg                               S_AXI_BVALID,
    input  wire                              S_AXI_BREADY,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_ARADDR,
    input  wire                              S_AXI_ARVALID,
    output reg                               S_AXI_ARREADY,

    output reg  [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_RDATA,
    output reg  [1:0]                        S_AXI_RRESP,
    output reg                               S_AXI_RVALID,
    input  wire                              S_AXI_RREADY,

    input  wire [31:0] frame_id,
    input  wire signed [31:0] laser1_um,
    input  wire signed [31:0] laser2_um,
    input  wire signed [31:0] laser3_um,
    input  wire signed [31:0] laser4_um,
    input  wire signed [31:0] laser5_um,
    input  wire signed [15:0] temperature_x10,
    input  wire [31:0] adc_a_raw_pp,
    input  wire [31:0] adc_b_raw_pp,
    input  wire [31:0] adc_a_filt_pp,
    input  wire [31:0] adc_b_filt_pp,

    input  wire [5:0] sensor_valid_seen,
    input  wire [5:0] sensor_crc_error,
    input  wire [5:0] sensor_timeout_error,
    input  wire [5:0] sensor_frame_error,

    // Reused long-frame command interface to pl_capture_logic.
    output reg                               adc_sample_rd_en,
    output reg  [ADC_ADDR_WIDTH-1:0]         adc_sample_rd_addr,
    input  wire [31:0]                       adc_sample_rd_data,

    // Runtime waveform length for the frame packer (samples per channel).
    output reg  [31:0]                       sample_count_cfg,

    // Active-high PL soft reset hold. Asserted/deasserted by PS writes to REG_WORD_MAGIC.
    output reg                               pl_soft_reset_hold
);

    localparam [3:0] REG_WORD_MAGIC          = 4'h0;  // 0x00 read magic / write PL reset hold control
    localparam [3:0] REG_WORD_FRAME_ID       = 4'h1;  // 0x04
    localparam [3:0] REG_WORD_LASER1         = 4'h2;  // 0x08
    localparam [3:0] REG_WORD_LASER2         = 4'h3;  // 0x0C
    localparam [3:0] REG_WORD_LASER3         = 4'h4;  // 0x10
    localparam [3:0] REG_WORD_LASER4         = 4'h5;  // 0x14
    localparam [3:0] REG_WORD_LASER5         = 4'h6;  // 0x18
    localparam [3:0] REG_WORD_TEMP           = 4'h7;  // 0x1C
    localparam [3:0] REG_WORD_STATUS         = 4'h8;  // 0x20
    localparam [3:0] REG_WORD_SAMPLE_COUNT   = 4'h9;  // 0x24 read/write runtime waveform length
    localparam [3:0] REG_WORD_ADC_A_RAW_PP   = 4'hA;  // 0x28
    localparam [3:0] REG_WORD_ADC_B_RAW_PP   = 4'hB;  // 0x2C
    localparam [3:0] REG_WORD_ADC_A_FILT_PP  = 4'hC;  // 0x30
    localparam [3:0] REG_WORD_ADC_B_FILT_PP  = 4'hD;  // 0x34
    localparam [3:0] REG_WORD_ADC_SAMPLE_IDX = 4'hE;  // 0x38 write/read
    localparam [3:0] REG_WORD_ADC_SAMPLE_DAT = 4'hF;  // 0x3C read

    localparam [31:0] PL_RESET_ASSERT_WORD   = 32'hA55A0001;
    localparam [31:0] PL_RESET_RELEASE_WORD  = 32'h00000000;
    localparam [31:0] CAPTURE_START_WORD     = 32'hCACE0001;
    localparam [31:0] DEFAULT_SAMPLE_COUNT   = 32'd4687500; // 0.3 s @ 15.625 MHz
    localparam [31:0] MIN_SAMPLE_COUNT       = 32'd16;      // moving-average filter length

    reg [C_S_AXI_ADDR_WIDTH-1:0] araddr_reg;

    reg [ADC_ADDR_WIDTH-1:0] adc_sample_addr_latched;
    reg [31:0]               capture_cmd_count;

    wire [31:0] status_word;
    assign status_word = {
        pl_soft_reset_hold,
        7'd0,
        sensor_frame_error,
        sensor_timeout_error,
        sensor_crc_error,
        sensor_valid_seen
    };

    function [31:0] read_mux;
        input [C_S_AXI_ADDR_WIDTH-1:0] addr;
        begin
            case (addr[5:2])
                REG_WORD_MAGIC:         read_mux = 32'hDA710005; // version 5: host-triggered long capture + sensor timeline
                REG_WORD_FRAME_ID:      read_mux = frame_id;
                REG_WORD_LASER1:        read_mux = laser1_um;
                REG_WORD_LASER2:        read_mux = laser2_um;
                REG_WORD_LASER3:        read_mux = laser3_um;
                REG_WORD_LASER4:        read_mux = laser4_um;
                REG_WORD_LASER5:        read_mux = laser5_um;
                REG_WORD_TEMP:          read_mux = {{16{temperature_x10[15]}}, temperature_x10};
                REG_WORD_STATUS:        read_mux = status_word;
                REG_WORD_SAMPLE_COUNT:  read_mux = sample_count_cfg;
                REG_WORD_ADC_A_RAW_PP:  read_mux = adc_a_raw_pp;
                REG_WORD_ADC_B_RAW_PP:  read_mux = adc_b_raw_pp;
                REG_WORD_ADC_A_FILT_PP: read_mux = adc_a_filt_pp;
                REG_WORD_ADC_B_FILT_PP: read_mux = adc_b_filt_pp;
                REG_WORD_ADC_SAMPLE_IDX:read_mux = {16'hCACE, capture_cmd_count[15:0]};
                REG_WORD_ADC_SAMPLE_DAT:read_mux = adc_sample_rd_data;
                default:                read_mux = 32'd0;
            endcase
        end
    endfunction

    // AXI-Lite read channel
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_ARREADY <= 1'b0;
            S_AXI_RVALID  <= 1'b0;
            S_AXI_RRESP   <= 2'b00;
            S_AXI_RDATA   <= 32'd0;
            araddr_reg    <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            S_AXI_ARREADY <= 1'b0;

            if (!S_AXI_RVALID && S_AXI_ARVALID) begin
                S_AXI_ARREADY <= 1'b1;
                araddr_reg    <= S_AXI_ARADDR;
                S_AXI_RDATA   <= read_mux(S_AXI_ARADDR);
                S_AXI_RRESP   <= 2'b00;
                S_AXI_RVALID  <= 1'b1;
            end else if (S_AXI_RVALID && S_AXI_RREADY) begin
                S_AXI_RVALID <= 1'b0;
            end
        end
    end

    // AXI-Lite write channel + waveform sample readback launcher.
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_AWREADY            <= 1'b0;
            S_AXI_WREADY             <= 1'b0;
            S_AXI_BVALID             <= 1'b0;
            S_AXI_BRESP              <= 2'b00;
            adc_sample_rd_en         <= 1'b0;
            adc_sample_rd_addr       <= {ADC_ADDR_WIDTH{1'b0}};
            adc_sample_addr_latched  <= {ADC_ADDR_WIDTH{1'b0}};
            capture_cmd_count        <= 32'd0;
            sample_count_cfg         <= DEFAULT_SAMPLE_COUNT;
            pl_soft_reset_hold       <= 1'b1;
        end else begin
            S_AXI_AWREADY    <= 1'b0;
            S_AXI_WREADY     <= 1'b0;
            adc_sample_rd_en <= 1'b0;

            if (!S_AXI_BVALID && S_AXI_AWVALID && S_AXI_WVALID) begin
                S_AXI_AWREADY <= 1'b1;
                S_AXI_WREADY  <= 1'b1;
                S_AXI_BVALID  <= 1'b1;
                S_AXI_BRESP   <= 2'b00;

                if (S_AXI_AWADDR[5:2] == REG_WORD_MAGIC) begin
                    if (S_AXI_WDATA == PL_RESET_ASSERT_WORD) begin
                        pl_soft_reset_hold <= 1'b1;
                    end else if (S_AXI_WDATA == PL_RESET_RELEASE_WORD) begin
                        pl_soft_reset_hold <= 1'b0;
                    end
                end else if (S_AXI_AWADDR[5:2] == REG_WORD_ADC_SAMPLE_IDX) begin
                    adc_sample_addr_latched <= S_AXI_WDATA[ADC_ADDR_WIDTH-1:0];
                    adc_sample_rd_addr      <= S_AXI_WDATA[ADC_ADDR_WIDTH-1:0];
                    if (S_AXI_WDATA == CAPTURE_START_WORD) begin
                        adc_sample_rd_en <= 1'b1;
                        capture_cmd_count <= capture_cmd_count + 1'b1;
                    end
                end else if (S_AXI_AWADDR[5:2] == REG_WORD_SAMPLE_COUNT) begin
                    if ((S_AXI_WDATA >= MIN_SAMPLE_COUNT) &&
                        (S_AXI_WDATA <= DEFAULT_SAMPLE_COUNT)) begin
                        sample_count_cfg <= S_AXI_WDATA;
                    end
                end
            end else if (S_AXI_BVALID && S_AXI_BREADY) begin
                S_AXI_BVALID <= 1'b0;
            end
        end
    end

endmodule
