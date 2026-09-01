`timescale 1ns / 1ps

/*
 * Module Contract
 *
 * 模块职责：
 * - 将一次错误事件转换为长度为 1 的响应 Payload，唯一字节为错误码。
 * - 先发出响应 RAM 写事件，再发出响应提交事件。
 * - 不负责：判定错误来源或错误码合法性、保存响应 RAM、补充 ADDR/CMD/SEQ 或发送帧。
 *
 * 输入事务：
 * - i_error_valid=1 的上升沿采样 i_error_code，开始一次错误响应事务。
 * - 模块没有 ready/busy/队列；上层不得在上一错误尚未提交时输入新错误。
 *
 * 输出事务：
 * - 接收错误的同一上升沿后，o_rsp_wr_en 有效 1clk，将错误码写到地址 0。
 * - o_rsp_length 恒为 1；o_rsp_wr_addr 恒为 0。
 * - 写脉冲后的下一拍产生 1clk 的 o_rsp_valid，表示错误 Payload 已写完。
 *
 * 关键时序：
 * - o_rsp_wr_data 仅在 o_rsp_wr_en=1 时作为有效写数据使用。
 * - 响应 RAM 应在 o_rsp_wr_en 有效的上升沿接收写入，并在后续 o_rsp_valid 时可供发送。
 *
 * 异常与恢复：
 * - reset：异步低有效，撤销写入和提交脉冲并清零写数据。
 * - abort：屏蔽当拍输入，撤销尚未发生的写入或提交；已被外部 RAM 接收的数据不回滚。
 * - 模块不因 abort 生成新的错误响应。
 *
 * 使用约束：
 * - 上层必须保证正常响应与错误响应互斥，并同时中止发送侧以取消已提交响应。
 * - 响应帧上下文由发送链路沿用当前请求，本模块不提供独立上下文。
 *
 * 参考：
 * - ERROR_RESPONSE.md：错误响应 Payload 和错误码约定。
 */
module error_response_generator (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_abort,
    input  wire        i_error_valid,
    input  wire [7:0]  i_error_code,

    output reg         o_rsp_wr_en,
    output wire [10:0] o_rsp_wr_addr,
    output reg  [7:0]  o_rsp_wr_data,
    output wire [15:0] o_rsp_length,
    output reg         o_rsp_valid
);

    /* 单字节 STATUS 始终写入响应 Payload 的第一个地址。 */
    assign o_rsp_wr_addr = 11'd0;
    assign o_rsp_length  = 16'd1;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_rsp_wr_en   <= 1'b0;
            o_rsp_wr_data <= 8'd0;
            o_rsp_valid   <= 1'b0;
        end else begin
            o_rsp_wr_en <= 1'b0;
            o_rsp_valid <= 1'b0;

            if (!i_abort) begin
                if (i_error_valid) begin
                    o_rsp_wr_data <= i_error_code;
                    o_rsp_wr_en   <= 1'b1;
                end

                /* 使用上一周期的写脉冲提交响应，无需额外状态机。 */
                if (o_rsp_wr_en) begin
                    o_rsp_valid <= 1'b1;
                end
            end
        end
    end

endmodule
