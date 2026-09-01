`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * Module Contract
 *
 * 模块职责：
 * - 实现控制类 demo 请求，查询或设置内部测试使能标志 o_demo_enable。
 * - 生成成功响应 RAM 写事件，或将命令、长度和参数错误提交给公共错误链路。
 * - 不负责：驱动实际控制硬件、保存响应 RAM、组帧或等待 UART 发送完成。
 *
 * 输入事务：
 * - 空闲时在 i_req_valid=1 的上升沿采样 CMD 和 LENGTH；处理期间忽略新请求。
 * - CTRL_READ 要求 LENGTH=0；CTRL_WRITE 要求 LENGTH=1，Payload[0] 只能为 0 或 1。
 * - 写命令从固定地址 0 读取 Payload，并等待 Parser RAM 的 1clk 同步读延迟。
 *
 * 输出事务：
 * - CTRL_READ 返回 STATUS_SUCCESS 和当前使能值，共 2 字节。
 * - CTRL_WRITE 成功更新 o_demo_enable，并返回单字节 STATUS_SUCCESS。
 * - 正常响应逐字节产生 o_rsp_wr_en，最后一次写入被接收后产生 1clk o_rsp_valid。
 * - 未知命令、错误长度或非法写值产生 1clk o_error_valid，不提交正常响应。
 *
 * 关键时序：
 * - 响应写接口无 ready；外部 RAM 必须在每个 o_rsp_wr_en 上升沿接收数据。
 * - o_rsp_valid、o_error_valid 和 o_rsp_wr_en 均为单周期事件。
 *
 * 异常与恢复：
 * - reset：异步低有效，回到空闲并将 o_demo_enable 清零。
 * - abort：优先取消当前读取或响应生成并回到空闲，不产生完成或错误事件。
 * - abort 不回滚此前已经更新的 o_demo_enable，也不清除外部 RAM 已接收的数据。
 *
 * 使用约束：
 * - 上层必须保证单事务，并保持请求上下文和 Payload 在本模块处理期间有效。
 * - i_req_seq 未被本模块使用；发送链路负责沿用当前请求的 CMD/SEQ。
 *
 * 参考：
 * - CMD_DEFINITION.md：控制类命令和响应状态定义。
 */
module demo_ctrl (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_abort,
    input  wire        i_req_valid,
    input  wire [7:0]  i_req_cmd,
    input  wire [7:0]  i_req_seq,
    input  wire [15:0] i_req_length,

    output wire [10:0] o_payload_rd_addr,
    input  wire [7:0]  i_payload_rd_data,

    output reg         o_rsp_wr_en,
    output reg  [10:0] o_rsp_wr_addr,
    output reg  [7:0]  o_rsp_wr_data,
    output reg  [15:0] o_rsp_length,
    output reg         o_rsp_valid,
    output reg         o_error_valid,
    output reg  [7:0]  o_error_code,

    output reg         o_demo_enable
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_READ_WAIT = 3'd1;
    localparam [2:0] ST_READ_BYTE = 3'd2;
    localparam [2:0] ST_RSP_WRITE = 3'd3;
    localparam [2:0] ST_RSP_DONE  = 3'd4;

    reg [2:0] state;
    reg       read_enable;
    reg       rsp_index;

    /* 本示例的写命令只需要读取 Payload 第一个字节。 */
    assign o_payload_rd_addr = 11'd0;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state         <= ST_IDLE;
            read_enable   <= 1'b0;
            rsp_index     <= 1'b0;
            o_demo_enable <= 1'b0;
            o_rsp_wr_en   <= 1'b0;
            o_rsp_wr_addr <= 11'd0;
            o_rsp_wr_data <= 8'd0;
            o_rsp_length  <= 16'd0;
            o_rsp_valid   <= 1'b0;
            o_error_valid <= 1'b0;
            o_error_code  <= 8'd0;
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
                            rsp_index <= 1'b0;
                            case (i_req_cmd)
                                `COMM_CMD_CTRL_READ: begin
                                    if (i_req_length == 16'd0) begin
                                        read_enable  <= o_demo_enable;
                                        o_rsp_length <= 16'd2;
                                        state        <= ST_RSP_WRITE;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end
                                `COMM_CMD_CTRL_WRITE: begin
                                    if (i_req_length == 16'd1) begin
                                        o_rsp_length <= 16'd1;
                                        state        <= ST_READ_WAIT;
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
                        /* 等待当前选通模块的同步 RAM 读数据就绪。 */
                        state <= ST_READ_BYTE;
                    end

                    ST_READ_BYTE: begin
                        if ((i_payload_rd_data == 8'd0) ||
                            (i_payload_rd_data == 8'd1)) begin
                            o_demo_enable <= i_payload_rd_data[0];
                            state         <= ST_RSP_WRITE;
                        end else begin
                            o_error_valid <= 1'b1;
                            o_error_code  <= `COMM_ERROR_PARAM;
                            state         <= ST_IDLE;
                        end
                    end

                    ST_RSP_WRITE: begin
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= {10'd0, rsp_index};
                        if (!rsp_index) begin
                            o_rsp_wr_data <= `COMM_STATUS_SUCCESS;
                        end else begin
                            o_rsp_wr_data <= {7'd0, read_enable};
                        end
                        if ((o_rsp_length == 16'd1) || rsp_index) begin
                            state <= ST_RSP_DONE;
                        end else begin
                            rsp_index <= 1'b1;
                        end
                    end

                    ST_RSP_DONE: begin
                        /* 响应数据写完后再发出一次提交事件。 */
                        o_rsp_valid <= 1'b1;
                        state       <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
