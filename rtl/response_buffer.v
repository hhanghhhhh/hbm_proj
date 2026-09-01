`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * Module Contract
 *
 * 模块职责：
 * - 在四个正常业务响应源和错误响应源之间选择一组完整响应接口。
 * - 将选中源的写使能、地址、数据、长度和提交事件组合转发给发送模块。
 * - 不负责：保存响应数据、检查长度/状态、仲裁并发事务或生成响应。
 *
 * 输入事务：
 * - 正常源由 i_active_module 组合选择；未选择业务模块时不转发正常响应。
 * - i_error_rsp_wr_en 或 i_error_rsp_valid 任一有效时，整组接口优先选择错误源。
 * - 模块没有时钟和采样事件，输入变化会经组合逻辑反映到输出。
 *
 * 输出事务：
 * - o_rsp_wr_en=1 时，地址和数据来自当前选中源；o_rsp_valid 原样转发提交事件。
 * - 没有选中正常模块且错误源不活动时，所有输出为 0。
 * - 模块不增加寄存级、脉冲展宽或握手反压。
 *
 * 关键时序：
 * - 错误源只在 wr_en/valid 有效周期获得优先级；两者均为 0 时立即恢复正常源选择。
 * - 响应源必须先完成全部 RAM 写入，再提交 rsp_valid；本模块不检查该顺序。
 *
 * 异常与恢复：
 * - 模块无 reset/abort/error 状态；复位和中止必须由各响应源及发送模块处理。
 * - 若多个正常源同时活动，只会转发 i_active_module 指定的源。
 *
 * 使用约束：
 * - 上层必须保证单事务，以及正常响应与错误响应不发生有害重叠。
 * - 错误响应写入过程中的空拍可能切回正常源，正常源在此期间不得发起写入或提交。
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
