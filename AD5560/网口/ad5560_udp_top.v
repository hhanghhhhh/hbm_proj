`timescale 1ns/1ps
`include "udp_cmd_defs.vh"
/* 通信与AD5560业务集成顶层，保留UDP应用层RX/TX端口供板级UDP/IP核接入。
 * ADC采样信号直接输入，不改动AD4114调度；Measurement不占用Driver资源池。
 * alarm_clear/fault_reset保留外部调试入口，本轮未增加对应UDP命令。 */
module ad5560_udp_top #(
    parameter SYS_CLK_FREQ=100_000_000,
    parameter SPI_CLK_FREQ=10_000_000,
    parameter BUSY_TIMEOUT_US=5
)(
    input wire i_clk,
    input wire i_rst_n,
    input wire [7:0] i_rx_byte,
    input wire i_rx_valid,
    input wire [15:0] i_rx_length,
    input wire i_udp_tx_ready,
    input wire i_udp_tx_ack,
    output wire o_udp_tx_request,
    output wire [15:0] o_udp_tx_length,
    output wire o_udp_tx_data_valid,
    output wire [7:0] o_udp_tx_data,
    output wire o_busy,
    output wire o_rx_crc_error,
    output wire o_rx_length_error,
    output wire o_rx_timeout,
    output wire o_transaction_timeout,
    input wire [7:0] i_alarm,
    input wire [7:0] i_busy_n,
    input wire [7:0] i_spi_miso,
    output wire [7:0] o_spi_sck,
    output wire [7:0] o_spi_mosi,
    output wire [127:0] o_sync_n,
    input wire i_sample_valid,
    input wire [7:0] i_sample_adc_id,
    input wire [2:0] i_sample_channel,
    input wire [23:0] i_sample_data,
    input wire i_alarm_clear_req,
    input wire i_alarm_clear_all,
    input wire i_fault_reset,
    output wire [7:0] o_sys_state,
    output wire [1:0] o_cfg_result,
    output wire [1:0] o_seq_result,
    output wire [7:0] o_fault_vector
);

wire cfg_ram_wr_en;
wire [9:0] cfg_ram_wr_addr;
wire [31:0] cfg_ram_wr_data;
wire [10:0] cfg_record_count;
wire [15:0] cfg_expected_crc;
wire cfg_crc_start;
wire cfg_crc_done;
wire cfg_crc_ok;
wire cfg_write_allowed;
wire cfg_start_allowed;
wire cfg_start_req;
wire seq_ram_wr_en;
wire [10:0] seq_ram_wr_addr;
wire [15:0] seq_ram_wr_data;
wire [11:0] seq_word_count;
wire [15:0] seq_expected_crc;
wire seq_crc_start;
wire seq_crc_done;
wire seq_crc_ok;
wire seq_write_allowed;
wire seq_start_allowed;
wire seq_start_req;
wire seq_mode;
wire [127:0] enable_mask;
wire result_rd_en;
wire [6:0] result_rd_addr;
wire result_rd_valid;
wire [47:0] result_rd_data;
wire cfg_busy, seq_busy, cfg_done, seq_done;
wire cfg_allowed, seq_allowed;
assign cfg_write_allowed=cfg_allowed && !cfg_busy;
assign seq_write_allowed=cfg_allowed && !seq_busy;
assign cfg_start_allowed=cfg_allowed;
assign seq_start_allowed=seq_allowed;
ad5560_udp_comm #(.SYS_CLK_FREQ(SYS_CLK_FREQ),.SPI_CLK_FREQ(SPI_CLK_FREQ),.BUSY_TIMEOUT_US(BUSY_TIMEOUT_US)) u_comm (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_rx_byte (i_rx_byte),
    .i_rx_valid (i_rx_valid),
    .i_rx_length (i_rx_length),
    .i_udp_tx_ready (i_udp_tx_ready),
    .i_udp_tx_ack (i_udp_tx_ack),
    .o_udp_tx_request (o_udp_tx_request),
    .o_udp_tx_length (o_udp_tx_length),
    .o_udp_tx_data_valid (o_udp_tx_data_valid),
    .o_udp_tx_data (o_udp_tx_data),
    .o_busy (o_busy),
    .o_rx_crc_error (o_rx_crc_error),
    .o_rx_length_error (o_rx_length_error),
    .o_rx_timeout (o_rx_timeout),
    .o_transaction_timeout (o_transaction_timeout),
    .o_cfg_ram_wr_en (cfg_ram_wr_en),
    .o_cfg_ram_wr_addr (cfg_ram_wr_addr),
    .o_cfg_ram_wr_data (cfg_ram_wr_data),
    .o_cfg_record_count (cfg_record_count),
    .o_cfg_expected_crc (cfg_expected_crc),
    .o_cfg_crc_start (cfg_crc_start),
    .i_cfg_crc_done (cfg_crc_done),
    .i_cfg_crc_ok (cfg_crc_ok),
    .i_cfg_write_allowed (cfg_write_allowed),
    .i_cfg_start_allowed (cfg_start_allowed),
    .o_cfg_start_req (cfg_start_req),
    .o_seq_ram_wr_en (seq_ram_wr_en),
    .o_seq_ram_wr_addr (seq_ram_wr_addr),
    .o_seq_ram_wr_data (seq_ram_wr_data),
    .o_seq_word_count (seq_word_count),
    .o_seq_expected_crc (seq_expected_crc),
    .o_seq_crc_start (seq_crc_start),
    .i_seq_crc_done (seq_crc_done),
    .i_seq_crc_ok (seq_crc_ok),
    .i_seq_write_allowed (seq_write_allowed),
    .i_seq_start_allowed (seq_start_allowed),
    .o_seq_start_req (seq_start_req),
    .o_seq_mode (seq_mode),
    .o_enable_mask (enable_mask),
    .o_result_rd_en (result_rd_en),
    .o_result_rd_addr (result_rd_addr),
    .i_result_rd_valid (result_rd_valid),
    .i_result_rd_data (result_rd_data),
    .i_sys_state (o_sys_state),
    .i_cfg_result (o_cfg_result),
    .i_seq_result (o_seq_result),
    .i_fault_vector (o_fault_vector)
);
ad5560_top #(.SYS_CLK_FREQ(SYS_CLK_FREQ),.SPI_CLK_FREQ(SPI_CLK_FREQ),.BUSY_TIMEOUT_US(BUSY_TIMEOUT_US)) u_ad5560_top (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_cfg_ram_wr_en (cfg_ram_wr_en),
    .i_cfg_ram_wr_addr (cfg_ram_wr_addr),
    .i_cfg_ram_wr_data (cfg_ram_wr_data),
    .i_cfg_record_count (cfg_record_count),
    .i_cfg_expected_crc (cfg_expected_crc),
    .i_cfg_crc_start (cfg_crc_start),
    .o_cfg_crc_done (cfg_crc_done),
    .o_cfg_crc_ok (cfg_crc_ok),
    .i_cfg_start_req (cfg_start_req),
    .i_seq_ram_wr_en (seq_ram_wr_en),
    .i_seq_ram_wr_addr (seq_ram_wr_addr),
    .i_seq_ram_wr_data (seq_ram_wr_data),
    .i_seq_word_count (seq_word_count),
    .i_seq_expected_crc (seq_expected_crc),
    .i_seq_crc_start (seq_crc_start),
    .o_seq_crc_done (seq_crc_done),
    .o_seq_crc_ok (seq_crc_ok),
    .i_seq_start_req (seq_start_req),
    .i_seq_mode (seq_mode),
    .i_alarm_clear_req (i_alarm_clear_req),
    .i_alarm_clear_all (i_alarm_clear_all),
    .i_fault_reset (i_fault_reset),
    .i_alarm_result_rd_addr (9'd0),
    .o_alarm_result_rd_data (),
    .o_cfg_busy (cfg_busy),
    .o_seq_busy (seq_busy),
    .o_cfg_done (cfg_done),
    .o_seq_done (seq_done),
    .o_sys_state (o_sys_state),
    .o_cfg_result (o_cfg_result),
    .o_seq_result (o_seq_result),
    .o_cfg_start_allowed (cfg_allowed),
    .o_seq_start_allowed (seq_allowed),
    .o_fault_vector_latched (o_fault_vector),
    .i_alarm (i_alarm),
    .i_busy_n (i_busy_n),
    .i_spi_miso (i_spi_miso),
    .o_spi_sck (o_spi_sck),
    .o_spi_mosi (o_spi_mosi),
    .o_sync_n (o_sync_n)
);
measurement_manager  u_measurement_manager (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_sample_valid (i_sample_valid),
    .i_sample_adc_id (i_sample_adc_id),
    .i_sample_channel (i_sample_channel),
    .i_sample_data (i_sample_data),
    .i_enable_mask (enable_mask),
    .i_result_rd_en (result_rd_en),
    .i_result_rd_addr (result_rd_addr),
    .o_result_rd_valid (result_rd_valid),
    .o_result_rd_data (result_rd_data)
);

endmodule
