`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * 模块说明
 *
 * 功能：
 * - 以纯组合逻辑在当前业务响应源和公共错误响应源之间选择整组响应接口，
 *   不保存 Payload，也不增加寄存延迟或反压。
 *
 * 关键约束：
 * - 正常响应由 i_active_module 选择；系统必须保证单事务以及响应源之间不发生
 *   有害重叠，各响应源须先写完 Payload 再提交 rsp_valid。
 *
 * 特殊行为：
 * - 错误源在 i_error_rsp_wr_en 或 i_error_rsp_valid 任一有效时优先，保证错误
 *   Payload 写入和提交均能通过。
 * - 错误写入过程的空拍会立即切回正常源，因此正常源在此期间不得发起动作。
 */
module response_buffer (
    input  wire [3:0]  i_active_module,

    input  wire        i_param_rsp_wr_en,
    input  wire [10:0] i_param_rsp_wr_addr,
    input  wire [7:0]  i_param_rsp_wr_data,
    input  wire [15:0] i_param_rsp_length,
    input  wire        i_param_rsp_valid,

    input  wire        i_ctrl_rsp_wr_en,
    input  wire [10:0] i_ctrl_rsp_wr_addr,
    input  wire [7:0]  i_ctrl_rsp_wr_data,
    input  wire [15:0] i_ctrl_rsp_length,
    input  wire        i_ctrl_rsp_valid,

    input  wire        i_config_rsp_wr_en,
    input  wire [10:0] i_config_rsp_wr_addr,
    input  wire [7:0]  i_config_rsp_wr_data,
    input  wire [15:0] i_config_rsp_length,
    input  wire        i_config_rsp_valid,

    input  wire        i_telemetry_rsp_wr_en,
    input  wire [10:0] i_telemetry_rsp_wr_addr,
    input  wire [7:0]  i_telemetry_rsp_wr_data,
    input  wire [15:0] i_telemetry_rsp_length,
    input  wire        i_telemetry_rsp_valid,

    input  wire        i_error_rsp_wr_en,
    input  wire [10:0] i_error_rsp_wr_addr,
    input  wire [7:0]  i_error_rsp_wr_data,
    input  wire [15:0] i_error_rsp_length,
    input  wire        i_error_rsp_valid,

    output reg         o_rsp_wr_en,
    output reg  [10:0] o_rsp_wr_addr,
    output reg  [7:0]  o_rsp_wr_data,
    output reg  [15:0] o_rsp_length,
    output reg         o_rsp_valid
);

    always @(*) begin
        /* 错误源在写数据和提交响应两个阶段均优先，不能只检查 rsp_valid。 */
        if (i_error_rsp_wr_en || i_error_rsp_valid) begin
            o_rsp_wr_en   = i_error_rsp_wr_en;
            o_rsp_wr_addr = i_error_rsp_wr_addr;
            o_rsp_wr_data = i_error_rsp_wr_data;
            o_rsp_length  = i_error_rsp_length;
            o_rsp_valid   = i_error_rsp_valid;
        end else if (i_active_module == `COMM_MODULE_PARAM) begin
            o_rsp_wr_en   = i_param_rsp_wr_en;
            o_rsp_wr_addr = i_param_rsp_wr_addr;
            o_rsp_wr_data = i_param_rsp_wr_data;
            o_rsp_length  = i_param_rsp_length;
            o_rsp_valid   = i_param_rsp_valid;
        end else if (i_active_module == `COMM_MODULE_CTRL) begin
            o_rsp_wr_en   = i_ctrl_rsp_wr_en;
            o_rsp_wr_addr = i_ctrl_rsp_wr_addr;
            o_rsp_wr_data = i_ctrl_rsp_wr_data;
            o_rsp_length  = i_ctrl_rsp_length;
            o_rsp_valid   = i_ctrl_rsp_valid;
        end else if (i_active_module == `COMM_MODULE_CONFIG) begin
            o_rsp_wr_en   = i_config_rsp_wr_en;
            o_rsp_wr_addr = i_config_rsp_wr_addr;
            o_rsp_wr_data = i_config_rsp_wr_data;
            o_rsp_length  = i_config_rsp_length;
            o_rsp_valid   = i_config_rsp_valid;
        end else if (i_active_module == `COMM_MODULE_TELEMETRY) begin
            o_rsp_wr_en   = i_telemetry_rsp_wr_en;
            o_rsp_wr_addr = i_telemetry_rsp_wr_addr;
            o_rsp_wr_data = i_telemetry_rsp_wr_data;
            o_rsp_length  = i_telemetry_rsp_length;
            o_rsp_valid   = i_telemetry_rsp_valid;
        end else begin
            o_rsp_wr_en   = 1'b0;
            o_rsp_wr_addr = 11'd0;
            o_rsp_wr_data = 8'd0;
            o_rsp_length  = 16'd0;
            o_rsp_valid   = 1'b0;
        end
    end

endmodule
