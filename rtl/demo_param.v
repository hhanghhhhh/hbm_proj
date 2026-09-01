`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * Module Contract
 *
 * 模块职责：
 * - 实现参数类 demo 请求，读取或原子更新 32 位内部测试寄存器 o_demo_param。
 * - 生成成功响应 RAM 写事件，或将命令/长度错误提交给公共错误链路。
 * - 不负责：解释其他参数、保存响应 RAM、组帧或等待 UART 发送完成。
 *
 * 输入事务：
 * - 空闲时在 i_req_valid=1 的上升沿采样 CMD 和 LENGTH；处理期间忽略新请求。
 * - PARAM_READ 要求 LENGTH=0；PARAM_WRITE 要求 LENGTH=4，Payload 为大端 32 位值。
 * - 写命令从地址 0..3 顺序读取 Payload，每个地址等待 Parser RAM 的 1clk 读延迟。
 *
 * 输出事务：
 * - PARAM_READ 返回 STATUS_SUCCESS，随后返回请求开始时快照的四字节大端参数值。
 * - PARAM_WRITE 收齐四字节后一次性更新 o_demo_param，并返回单字节 STATUS_SUCCESS。
 * - 正常响应全部写入后产生 1clk o_rsp_valid；错误产生 1clk o_error_valid 且无正常响应。
 *
 * 关键时序：
 * - o_rsp_wr_en 每个有效周期写一个字节，外部响应 RAM 接口没有反压。
 * - o_rsp_wr_en、o_rsp_valid 和 o_error_valid 均为单周期事件。
 * - 参数写入仅在第四个 Payload 字节返回时提交，不暴露部分更新值。
 *
 * 异常与恢复：
 * - reset：异步低有效，回到空闲并将 o_demo_param 清零。
 * - abort：取消当前读取或响应生成并回到空闲，不产生完成或错误事件。
 * - abort 不回滚已完整提交的参数，也不清除外部 RAM 已接收的响应字节。
 *
 * 使用约束：
 * - 上层必须保证单事务，并保持请求上下文和 Payload 在处理期间有效。
 * - i_req_seq 未被使用；响应帧 CMD/SEQ 由外部发送链路沿用当前请求。
 *
 * 参考：
 * - CMD_DEFINITION.md：参数类命令和响应状态定义。
 */
module demo_param (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_abort,
    input  wire        i_req_valid,
    input  wire [7:0]  i_req_cmd,
    input  wire [7:0]  i_req_seq,
    input  wire [15:0] i_req_length,

    output reg  [10:0] o_payload_rd_addr,
    input  wire [7:0]  i_payload_rd_data,

    output reg         o_rsp_wr_en,
    output reg  [10:0] o_rsp_wr_addr,
    output reg  [7:0]  o_rsp_wr_data,
    output reg  [15:0] o_rsp_length,
    output reg         o_rsp_valid,
    output reg         o_error_valid,
    output reg  [7:0]  o_error_code,

    output reg  [31:0] o_demo_param
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_READ_WAIT = 3'd1;
    localparam [2:0] ST_READ_BYTE = 3'd2;
    localparam [2:0] ST_RSP_WRITE = 3'd3;
    localparam [2:0] ST_RSP_DONE  = 3'd4;

    reg [2:0]  state;
    reg [31:0] write_value;
    reg [31:0] read_value;
    reg [2:0]  rsp_index;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state             <= ST_IDLE;
            write_value       <= 32'd0;
            read_value        <= 32'd0;
            rsp_index         <= 3'd0;
            o_demo_param      <= 32'd0;
            o_payload_rd_addr <= 11'd0;
            o_rsp_wr_en       <= 1'b0;
            o_rsp_wr_addr     <= 11'd0;
            o_rsp_wr_data     <= 8'd0;
            o_rsp_length      <= 16'd0;
            o_rsp_valid       <= 1'b0;
            o_error_valid     <= 1'b0;
            o_error_code      <= 8'd0;
        end else begin
            o_rsp_wr_en   <= 1'b0;
            o_rsp_valid   <= 1'b0;
            o_error_valid <= 1'b0;

            if (i_abort) begin
                state <= ST_IDLE;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (i_req_valid) begin
                            rsp_index <= 3'd0;
                            case (i_req_cmd)
                                `COMM_CMD_PARAM_READ: begin
                                    if (i_req_length == 16'd0) begin
                                        /* 对读请求保存当前值，响应按大端顺序返回。 */
                                        read_value   <= o_demo_param;
                                        o_rsp_length <= 16'd5;
                                        state        <= ST_RSP_WRITE;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end
                                `COMM_CMD_PARAM_WRITE: begin
                                    if (i_req_length == 16'd4) begin
                                        write_value       <= 32'd0;
                                        o_payload_rd_addr <= 11'd0;
                                        o_rsp_length      <= 16'd1;
                                        state             <= ST_READ_WAIT;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end
                                default: begin
                                    o_error_valid <= 1'b1;
                                    o_error_code  <= `COMM_ERROR_UNKNOWN_CMD;
                                end
                            endcase
                        end
                    end

                    ST_READ_WAIT: begin
                        /* 地址已输出，本周期等待同步 RAM 更新读数据。 */
                        state <= ST_READ_BYTE;
                    end

                    ST_READ_BYTE: begin
                        write_value <= {write_value[23:0], i_payload_rd_data};
                        if (o_payload_rd_addr == 11'd3) begin
                            o_demo_param <= {write_value[23:0], i_payload_rd_data};
                            state        <= ST_RSP_WRITE;
                        end else begin
                            o_payload_rd_addr <= o_payload_rd_addr + 1'b1;
                            state             <= ST_READ_WAIT;
                        end
                    end

                    ST_RSP_WRITE: begin
                        /* 写接口无反压，每个 wr_en 周期向响应 RAM 提交一个字节。 */
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= {8'd0, rsp_index};
                        case (rsp_index)
                            3'd0:    o_rsp_wr_data <= `COMM_STATUS_SUCCESS;
                            3'd1:    o_rsp_wr_data <= read_value[31:24];
                            3'd2:    o_rsp_wr_data <= read_value[23:16];
                            3'd3:    o_rsp_wr_data <= read_value[15:8];
                            default: o_rsp_wr_data <= read_value[7:0];
                        endcase
                        if ((o_rsp_length == 16'd1) || (rsp_index == 3'd4)) begin
                            state <= ST_RSP_DONE;
                        end else begin
                            rsp_index <= rsp_index + 1'b1;
                        end
                    end

                    ST_RSP_DONE: begin
                        /* 最后一个写脉冲在本时钟沿被 RAM 接收，随后提交响应。 */
                        o_rsp_valid <= 1'b1;
                        state       <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
