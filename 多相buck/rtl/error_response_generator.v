`timescale 1ns / 1ps

/*
 * 模块说明
 *
 * 功能：
 * - 将公共错误事件转换为单字节错误响应 Payload；内容直接使用 i_error_code。
 * - 不判断错误来源或编号，也不保存 ADDR、CMD、SEQ 等请求上下文。
 *
 * 关键数据：
 * - 错误响应 LENGTH 固定为 1，错误码固定写入响应 RAM 地址 0。
 *
 * 关键约束：
 * - 上层必须保证正常响应与错误响应互斥，并由发送链路沿用当前请求上下文。
 *
 * 特殊行为：
 * - 先写入响应 RAM，下一拍才提交响应，保证发送侧读取时 Payload 已有效。
 * - i_abort 可撤销尚未提交的错误响应，但不回滚外部 RAM 已接收的写入。
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
