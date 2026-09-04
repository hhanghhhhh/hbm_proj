`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * 模块说明
 *
 * 功能：
 * - 按 CMD 高四位将合法请求分发给参数、控制、配置或遥测业务模块。
 * - 保存并广播 CMD、SEQ、LENGTH，同时选择当前业务的 Payload RAM 读地址。
 *
 * 关键约束：
 * - 本模块只识别命令类别，类别内子命令及 Payload 语义由业务模块处理。
 * - o_active_module 和请求上下文在正常响应结束后仍保留，直到新请求覆盖或
 *   i_abort 清除；系统必须保证同一时刻只有一个通信事务在途。
 * - Payload 读数据直接广播，不增加 Parser RAM 原有的同步读延迟。
 *
 * 特殊行为：
 * - 未接入的命令类别不选通业务模块，并提交 COMM_ERROR_UNKNOWN_CMD。
 * - 模块不提供 busy、ready 或队列；新请求可直接覆盖已有上下文。
 */
module cmd_dispatcher (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_abort,

    input  wire        i_frame_valid,
    input  wire [7:0]  i_frame_cmd,
    input  wire [7:0]  i_frame_seq,
    input  wire [15:0] i_frame_length,

    output reg  [7:0]  o_req_cmd,
    output reg  [7:0]  o_req_seq,
    output reg  [15:0] o_req_length,
    output wire [7:0]  o_payload_rd_data,
    output reg         o_param_req_valid,
    output reg         o_ctrl_req_valid,
    output reg         o_config_req_valid,
    output reg         o_telemetry_req_valid,
    output reg  [3:0]  o_active_module,

    input  wire [10:0] i_param_payload_rd_addr,
    input  wire [10:0] i_ctrl_payload_rd_addr,
    input  wire [10:0] i_config_payload_rd_addr,
    input  wire [10:0] i_telemetry_payload_rd_addr,
    output reg  [10:0] o_payload_rd_addr,
    input  wire [7:0]  i_payload_rd_data,

    output reg         o_error_valid,
    output reg  [7:0]  o_error_code
);

    /* 读数据不寄存，保留 Parser RAM 原有的同步读时序。 */
    assign o_payload_rd_data = i_payload_rd_data;

    always @(*) begin
        case (o_active_module)
            `COMM_MODULE_PARAM: o_payload_rd_addr = i_param_payload_rd_addr;
            `COMM_MODULE_CTRL:  o_payload_rd_addr = i_ctrl_payload_rd_addr;
            `COMM_MODULE_CONFIG: o_payload_rd_addr = i_config_payload_rd_addr;
            `COMM_MODULE_TELEMETRY:
                o_payload_rd_addr = i_telemetry_payload_rd_addr;
            default:            o_payload_rd_addr = 11'd0;
        endcase
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_req_cmd         <= 8'd0;
            o_req_seq         <= 8'd0;
            o_req_length      <= 16'd0;
            o_param_req_valid <= 1'b0;
            o_ctrl_req_valid  <= 1'b0;
            o_config_req_valid <= 1'b0;
            o_telemetry_req_valid <= 1'b0;
            o_active_module   <= `COMM_MODULE_NONE;
            o_error_valid     <= 1'b0;
            o_error_code      <= 8'd0;
        end else begin
            o_param_req_valid <= 1'b0;
            o_ctrl_req_valid  <= 1'b0;
            o_config_req_valid <= 1'b0;
            o_telemetry_req_valid <= 1'b0;
            o_error_valid    <= 1'b0;

            if (i_abort) begin
                o_req_cmd       <= 8'd0;
                o_req_seq       <= 8'd0;
                o_req_length    <= 16'd0;
                o_active_module <= `COMM_MODULE_NONE;
                o_error_code    <= 8'd0;
            end else if (i_frame_valid) begin
                /* 元信息和请求脉冲同时寄存，业务模块在下一时钟沿采样。 */
                o_req_cmd    <= i_frame_cmd;
                o_req_seq    <= i_frame_seq;
                o_req_length <= i_frame_length;

                case (i_frame_cmd[7:4])
                    `COMM_CLASS_PARAM: begin
                        o_active_module   <= `COMM_MODULE_PARAM;
                        o_param_req_valid <= 1'b1;
                    end
                    `COMM_CLASS_CTRL: begin
                        o_active_module  <= `COMM_MODULE_CTRL;
                        o_ctrl_req_valid <= 1'b1;
                    end
                    `COMM_CLASS_CONFIG: begin
                        o_active_module    <= `COMM_MODULE_CONFIG;
                        o_config_req_valid <= 1'b1;
                    end
                    `COMM_CLASS_TELEMETRY: begin
                        o_active_module       <= `COMM_MODULE_TELEMETRY;
                        o_telemetry_req_valid <= 1'b1;
                    end
                    default: begin
                        o_active_module <= `COMM_MODULE_NONE;
                        o_error_valid   <= 1'b1;
                        o_error_code    <= `COMM_ERROR_UNKNOWN_CMD;
                    end
                endcase
            end
        end
    end

endmodule
