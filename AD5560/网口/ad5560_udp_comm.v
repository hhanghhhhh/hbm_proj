`timescale 1ns/1ps
`include "udp_cmd_defs.vh"
/* UDP业务通信顶层：Parser -> Dispatcher -> 四类业务 -> 响应MUX -> TX。
 * 单事务，TX完成才释放Parser；业务/帧CRC分离，不含串口控制或重发去重缓存。 */
module ad5560_udp_comm #(
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
    output wire o_cfg_ram_wr_en,
    output wire [9:0] o_cfg_ram_wr_addr,
    output wire [31:0] o_cfg_ram_wr_data,
    output wire [10:0] o_cfg_record_count,
    output wire [15:0] o_cfg_expected_crc,
    output wire o_cfg_crc_start,
    input wire i_cfg_crc_done,
    input wire i_cfg_crc_ok,
    input wire i_cfg_write_allowed,
    input wire i_cfg_start_allowed,
    output wire o_cfg_start_req,
    output wire o_seq_ram_wr_en,
    output wire [10:0] o_seq_ram_wr_addr,
    output wire [15:0] o_seq_ram_wr_data,
    output wire [11:0] o_seq_word_count,
    output wire [15:0] o_seq_expected_crc,
    output wire o_seq_crc_start,
    input wire i_seq_crc_done,
    input wire i_seq_crc_ok,
    input wire i_seq_write_allowed,
    input wire i_seq_start_allowed,
    output wire o_seq_start_req,
    output wire o_seq_mode,
    output wire [127:0] o_enable_mask,
    output wire o_result_rd_en,
    output wire [6:0] o_result_rd_addr,
    input wire i_result_rd_valid,
    input wire [47:0] i_result_rd_data,
    input wire [7:0] i_sys_state,
    input wire [1:0] i_cfg_result,
    input wire [1:0] i_seq_result,
    input wire [7:0] i_fault_vector
);

wire frame_valid, frame_done;
wire [7:0] frame_cmd, frame_seq, req_cmd, req_seq, payload_data;
wire [15:0] frame_length, req_length;
wire [10:0] payload_addr, config_addr, power_addr, telemetry_addr;
wire config_req, power_req, telemetry_req, status_req, dispatcher_error;
wire [7:0] dispatcher_code;
wire [2:0] active_module;
wire abort_request = o_transaction_timeout;
wire config_wr_en, config_valid;
wire [10:0] config_wr_addr;
wire [7:0] config_wr_data;
wire [15:0] config_length;
wire config_error;
wire [7:0] config_code;
wire power_wr_en, power_valid;
wire [10:0] power_wr_addr;
wire [7:0] power_wr_data;
wire [15:0] power_length;
wire power_error;
wire [7:0] power_code;
wire telemetry_wr_en, telemetry_valid;
wire [10:0] telemetry_wr_addr;
wire [7:0] telemetry_wr_data;
wire [15:0] telemetry_length;
wire telemetry_error;
wire [7:0] telemetry_code;
wire status_wr_en, status_valid;
wire [10:0] status_wr_addr;
wire [7:0] status_wr_data;
wire [15:0] status_length;
wire status_error;
wire [7:0] status_code;
wire error_wr_en, error_valid;
wire [10:0] error_wr_addr;
wire [7:0] error_wr_data;
wire [15:0] error_length;
udp_frame_parser #(.CLK_FREQ_HZ(SYS_CLK_FREQ)) u_parser (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_rx_byte (i_rx_byte),
    .i_rx_valid (i_rx_valid),
    .i_rx_length (i_rx_length),
    .i_frame_done (frame_done),
    .o_busy (o_busy),
    .o_frame_valid (frame_valid),
    .o_cmd (frame_cmd),
    .o_seq (frame_seq),
    .o_payload_length (frame_length),
    .i_payload_rd_addr (payload_addr),
    .o_payload_rd_data (payload_data),
    .o_rx_timeout (o_rx_timeout),
    .o_length_error (o_rx_length_error),
    .o_crc_error (o_rx_crc_error),
    .o_transaction_timeout (o_transaction_timeout)
);
udp_cmd_dispatcher  u_dispatcher (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_abort (abort_request),
    .i_frame_valid (frame_valid),
    .i_frame_cmd (frame_cmd),
    .i_frame_seq (frame_seq),
    .i_frame_length (frame_length),
    .o_req_cmd (req_cmd),
    .o_req_seq (req_seq),
    .o_req_length (req_length),
    .o_active_module (active_module),
    .o_config_req (config_req),
    .o_power_req (power_req),
    .o_telemetry_req (telemetry_req),
    .o_status_req (status_req),
    .i_config_rd_addr (config_addr),
    .i_power_rd_addr (power_addr),
    .i_telemetry_rd_addr (telemetry_addr),
    .o_payload_rd_addr (payload_addr),
    .o_error_valid (dispatcher_error),
    .o_error_code (dispatcher_code)
);
wire [10:0] config_mem_addr;
wire [11:0] config_count;
wire [31:0] power_mem_data;
assign o_cfg_ram_wr_addr=config_mem_addr[9:0];
assign o_cfg_record_count=config_count[10:0];
assign o_seq_ram_wr_data=power_mem_data[15:0];
udp_image_application #(.IS_POWER(0)) u_config_application (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_abort (abort_request),
    .i_req_valid (config_req),
    .i_req_cmd (req_cmd),
    .i_req_length (req_length),
    .o_payload_rd_addr (config_addr),
    .i_payload_rd_data (payload_data),
    .o_rsp_wr_en (config_wr_en),
    .o_rsp_wr_addr (config_wr_addr),
    .o_rsp_wr_data (config_wr_data),
    .o_rsp_length (config_length),
    .o_rsp_valid (config_valid),
    .o_error_valid (config_error),
    .o_error_code (config_code),
    .i_write_allowed (i_cfg_write_allowed),
    .i_start_allowed (i_cfg_start_allowed),
    .o_ram_wr_en (o_cfg_ram_wr_en),
    .o_ram_wr_addr (config_mem_addr),
    .o_ram_wr_data (o_cfg_ram_wr_data),
    .o_word_count (config_count),
    .o_expected_crc (o_cfg_expected_crc),
    .o_crc_start (o_cfg_crc_start),
    .i_crc_done (i_cfg_crc_done),
    .i_crc_ok (i_cfg_crc_ok),
    .o_start_req (o_cfg_start_req),
    .o_mode ()
);
udp_image_application #(.IS_POWER(1)) u_power_application (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_abort (abort_request),
    .i_req_valid (power_req),
    .i_req_cmd (req_cmd),
    .i_req_length (req_length),
    .o_payload_rd_addr (power_addr),
    .i_payload_rd_data (payload_data),
    .o_rsp_wr_en (power_wr_en),
    .o_rsp_wr_addr (power_wr_addr),
    .o_rsp_wr_data (power_wr_data),
    .o_rsp_length (power_length),
    .o_rsp_valid (power_valid),
    .o_error_valid (power_error),
    .o_error_code (power_code),
    .i_write_allowed (i_seq_write_allowed),
    .i_start_allowed (i_seq_start_allowed),
    .o_ram_wr_en (o_seq_ram_wr_en),
    .o_ram_wr_addr (o_seq_ram_wr_addr),
    .o_ram_wr_data (power_mem_data),
    .o_word_count (o_seq_word_count),
    .o_expected_crc (o_seq_expected_crc),
    .o_crc_start (o_seq_crc_start),
    .i_crc_done (i_seq_crc_done),
    .i_crc_ok (i_seq_crc_ok),
    .o_start_req (o_seq_start_req),
    .o_mode (o_seq_mode)
);
udp_telemetry_application  u_telemetry_application (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_abort (abort_request),
    .i_req_valid (telemetry_req),
    .i_req_cmd (req_cmd),
    .i_req_length (req_length),
    .o_payload_rd_addr (telemetry_addr),
    .i_payload_rd_data (payload_data),
    .o_rsp_wr_en (telemetry_wr_en),
    .o_rsp_wr_addr (telemetry_wr_addr),
    .o_rsp_wr_data (telemetry_wr_data),
    .o_rsp_length (telemetry_length),
    .o_rsp_valid (telemetry_valid),
    .o_error_valid (telemetry_error),
    .o_error_code (telemetry_code),
    .o_enable_mask (o_enable_mask),
    .o_result_rd_en (o_result_rd_en),
    .o_result_rd_addr (o_result_rd_addr),
    .i_result_rd_valid (i_result_rd_valid),
    .i_result_rd_data (i_result_rd_data)
);
udp_status_application  u_status_application (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_abort (abort_request),
    .i_req_valid (status_req),
    .i_req_length (req_length),
    .o_rsp_wr_en (status_wr_en),
    .o_rsp_wr_addr (status_wr_addr),
    .o_rsp_wr_data (status_wr_data),
    .o_rsp_length (status_length),
    .o_rsp_valid (status_valid),
    .o_error_valid (status_error),
    .o_error_code (status_code),
    .i_sys_state (i_sys_state),
    .i_cfg_result (i_cfg_result),
    .i_seq_result (i_seq_result),
    .i_fault_vector (i_fault_vector)
);
wire app_error = dispatcher_error || config_error || power_error || telemetry_error || status_error;
wire [7:0] app_error_code = dispatcher_error ? dispatcher_code : config_error ? config_code : power_error ? power_code : telemetry_error ? telemetry_code : status_code;
udp_error_response  u_error_response (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_abort (abort_request),
    .i_error_valid (app_error),
    .i_error_code (app_error_code),
    .o_rsp_wr_en (error_wr_en),
    .o_rsp_wr_addr (error_wr_addr),
    .o_rsp_wr_data (error_wr_data),
    .o_rsp_length (error_length),
    .o_rsp_valid (error_valid)
);
reg mux_wr_en, mux_valid;
reg [10:0] mux_wr_addr;
reg [7:0] mux_wr_data;
reg [15:0] mux_length;
always @(*) begin
    mux_wr_en=0; mux_valid=0; mux_wr_addr=0; mux_wr_data=0; mux_length=1;
    if(error_wr_en || error_valid) begin
        mux_wr_en=error_wr_en; mux_valid=error_valid; mux_wr_addr=error_wr_addr;
        mux_wr_data=error_wr_data; mux_length=error_length;
    end else begin
        case(active_module)
            `UDP_APP_CONFIG: begin
                mux_wr_en=config_wr_en; mux_valid=config_valid; mux_wr_addr=config_wr_addr;
                mux_wr_data=config_wr_data; mux_length=config_length;
            end
            `UDP_APP_POWER: begin
                mux_wr_en=power_wr_en; mux_valid=power_valid; mux_wr_addr=power_wr_addr;
                mux_wr_data=power_wr_data; mux_length=power_length;
            end
            `UDP_APP_TELEMETRY: begin
                mux_wr_en=telemetry_wr_en; mux_valid=telemetry_valid; mux_wr_addr=telemetry_wr_addr;
                mux_wr_data=telemetry_wr_data; mux_length=telemetry_length;
            end
            `UDP_APP_STATUS: begin
                mux_wr_en=status_wr_en; mux_valid=status_valid; mux_wr_addr=status_wr_addr;
                mux_wr_data=status_wr_data; mux_length=status_length;
            end
            default: ;
        endcase
    end
end
udp_tx_frame_builder  u_tx_builder (
    .i_clk (i_clk),
    .i_rst_n (i_rst_n),
    .i_abort (abort_request),
    .i_rsp_wr_en (mux_wr_en),
    .i_rsp_wr_addr (mux_wr_addr),
    .i_rsp_wr_data (mux_wr_data),
    .i_rsp_length (mux_length),
    .i_rsp_valid (mux_valid),
    .i_req_cmd (req_cmd),
    .i_req_seq (req_seq),
    .i_udp_tx_ready (i_udp_tx_ready),
    .i_udp_tx_ack (i_udp_tx_ack),
    .o_udp_tx_request (o_udp_tx_request),
    .o_udp_tx_length (o_udp_tx_length),
    .o_udp_tx_data_valid (o_udp_tx_data_valid),
    .o_udp_tx_data (o_udp_tx_data),
    .o_busy (),
    .o_tx_done (frame_done),
    .o_length_error ()
);

endmodule
