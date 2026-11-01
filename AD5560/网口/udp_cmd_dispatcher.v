`timescale 1ns/1ps
`include "udp_cmd_defs.vh"
/* 保存单笔请求上下文，分发业务脉冲并选择 Parser 的同步读地址。
 * 继承旧 cmd_dispatcher 的结构；只选通本轮实现的精确 CMD。
 */
module udp_cmd_dispatcher (
    input wire i_clk, input wire i_rst_n, input wire i_abort,
    input wire i_frame_valid,
    input wire [7:0] i_frame_cmd, input wire [7:0] i_frame_seq,
    input wire [15:0] i_frame_length,
    output reg [7:0] o_req_cmd, output reg [7:0] o_req_seq,
    output reg [15:0] o_req_length,
    output reg [2:0] o_active_module,
    output reg o_config_req, output reg o_power_req,
    output reg o_telemetry_req, output reg o_status_req,
    input wire [10:0] i_config_rd_addr, input wire [10:0] i_power_rd_addr,
    input wire [10:0] i_telemetry_rd_addr,
    output reg [10:0] o_payload_rd_addr,
    output reg o_error_valid, output wire [7:0] o_error_code
);
assign o_error_code = `UDP_UNKNOWN_CMD;
always @(*) begin
    o_payload_rd_addr = 11'd0;
    case (o_active_module)
        `UDP_APP_CONFIG: o_payload_rd_addr = i_config_rd_addr;
        `UDP_APP_POWER: o_payload_rd_addr = i_power_rd_addr;
        `UDP_APP_TELEMETRY: o_payload_rd_addr = i_telemetry_rd_addr;
        default: ;
    endcase
end
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        o_req_cmd <= 0; o_req_seq <= 0; o_req_length <= 0;
        o_active_module <= `UDP_APP_NONE;
        o_config_req <= 0; o_power_req <= 0;
        o_telemetry_req <= 0; o_status_req <= 0; o_error_valid <= 0;
    end else begin
        o_config_req <= 0; o_power_req <= 0;
        o_telemetry_req <= 0; o_status_req <= 0; o_error_valid <= 0;
        if (i_abort) o_active_module <= `UDP_APP_NONE;
        else if (i_frame_valid) begin
            o_req_cmd <= i_frame_cmd; o_req_seq <= i_frame_seq;
            o_req_length <= i_frame_length;
            case (i_frame_cmd)
                `UDP_CMD_CONFIG_DATA, `UDP_CMD_CONFIG_START: begin
                    o_active_module <= `UDP_APP_CONFIG; o_config_req <= 1;
                end
                `UDP_CMD_POWER_DATA, `UDP_CMD_POWER_START: begin
                    o_active_module <= `UDP_APP_POWER; o_power_req <= 1;
                end
                `UDP_CMD_TEL_ENABLE, `UDP_CMD_TEL_READ: begin
                    o_active_module <= `UDP_APP_TELEMETRY; o_telemetry_req <= 1;
                end
                `UDP_CMD_SYSTEM_STATUS: begin
                    o_active_module <= `UDP_APP_STATUS; o_status_req <= 1;
                end
                default: begin
                    o_active_module <= `UDP_APP_NONE; o_error_valid <= 1;
                end
            endcase
        end
    end
end
endmodule
