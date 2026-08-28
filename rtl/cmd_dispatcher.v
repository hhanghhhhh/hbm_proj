`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * 合法请求的类别分发与 Payload RAM 读地址选择模块。
 *
 * Frame Parser 提交 i_frame_valid 时，本模块锁存 CMD/SEQ/LENGTH，
 * 根据 CMD 高四位选择业务模块，并产生对应的单周期 req_valid。
 * req_cmd/req_seq/req_length 和 Payload 读数据广播给各业务模块，
 * 仅被 req_valid 选中的模块开始处理。类别内的子命令由业务模块识别；
 * 未接入类别只产生 error_valid/error_code，不选通业务模块。
 *
 * 系统严格单条请求一收一发，不设 busy、ready、队列或完成输入。
 * 正常响应结束后继续保留上下文和 active_module，下一条合法请求
 * 直接覆盖；i_abort 接 Frame Parser 的事务超时脉冲，清除当前选择。
 *
 * 业务模块由上层独立例化，不在本模块内部例化。
 * Payload RAM 位于 Frame Parser 内部，地址组合选择、数据直接广播，
 * 不增加 RAM 的 1clk 同步读延迟。没有业务选中时地址输出为 0。
 * 新增业务时只需增加类别译码、请求选通和读地址分支。
 * 所有接口使用同一个 i_clk，i_rst_n 为异步低有效复位。
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
    output reg  [1:0]  o_active_module,

    input  wire [10:0] i_param_payload_rd_addr,
    input  wire [10:0] i_ctrl_payload_rd_addr,
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
            o_active_module   <= `COMM_MODULE_NONE;
            o_error_valid     <= 1'b0;
            o_error_code      <= 8'd0;
        end else begin
            o_param_req_valid <= 1'b0;
            o_ctrl_req_valid  <= 1'b0;
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
