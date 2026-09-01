`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * Module Contract
 *
 * 模块职责：
 * - 按请求 CMD 的高四位选择参数、控制、配置或遥测业务，并广播请求上下文。
 * - 将当前业务模块的 Payload 读地址接到 Parser RAM，原样广播返回数据。
 * - 不负责：识别类别内子命令、例化业务模块、保存 Payload 或等待响应完成。
 *
 * 输入事务：
 * - i_frame_valid=1 的上升沿采样 i_frame_cmd/i_frame_seq/i_frame_length。
 * - 已接入类别在同一沿更新公共请求字段和 o_active_module，并置位对应 req_valid。
 * - 模块没有 busy/ready；新的 i_frame_valid 会覆盖此前保存的请求上下文。
 *
 * 输出事务：
 * - 四路 req_valid 和 o_error_valid 均为 1clk pulse，且一次请求至多产生其中一路。
 * - 未接入的 CMD 类别不选通业务模块，输出 COMM_ERROR_UNKNOWN_CMD 错误事件。
 * - o_active_module 和公共请求字段保持到下一次合法请求覆盖、abort 或 reset。
 *
 * 关键时序：
 * - 业务模块在 req_valid 有效的上升沿之后看到已寄存的公共请求字段。
 * - o_payload_rd_addr 组合选择当前 active_module 的地址；无选择时为 0。
 * - o_payload_rd_data 直接连接 i_payload_rd_data，不增加 Parser RAM 固有读延迟。
 *
 * 异常与恢复：
 * - reset：异步低有效，清除请求上下文、模块选择和所有事件输出。
 * - abort：优先于 i_frame_valid，清除上下文和选择，不产生请求或错误事件。
 * - error：错误码保持到后续错误、abort 或 reset，但仅在 o_error_valid 时有效。
 *
 * 使用约束：
 * - 上层必须保证同一时刻最多一个通信事务在途，且仅被选中的业务模块发起 RAM 读。
 * - i_abort 用于取消当前选择；正常事务结束本身不会自动清除 o_active_module。
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
