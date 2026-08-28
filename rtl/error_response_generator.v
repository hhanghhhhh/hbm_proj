`timescale 1ns / 1ps

/*
 * 单字节错误响应 Payload 生成器。
 *
 * Dispatcher 和业务模块的错误请求由顶层选择后接入本模块，输入为
 * 单周期 i_error_valid 及对应的非零 i_error_code。本模块不解释错误
 * 来源或编号，也不接收 Parser 的帧校验错误，不增加错误码合法性检查。
 *
 * 错误响应固定 LENGTH=1，Payload 只有 STATUS，内容直接使用 error_code。
 * 收到错误请求后寄存数据并产生单周期 o_rsp_wr_en，向外部响应 RAM
 * 的地址 0 写入 STATUS；下一时钟沿 RAM 接收该写入，随后产生单周期
 * o_rsp_valid，通知 TX Frame Builder 开始发送。
 *
 * rsp_* 接 Response Buffer 的错误响应输入。没有内部 RAM 或 CRC，
 * 不接收 ADDR/CMD/SEQ，响应上下文由 TX Frame Builder 沿用当前请求。
 * 系统保证单条请求一收一发、正常与错误响应互斥；本模块不设队列、
 * busy、ready、frame_done 或 tx_done，也不等待 UART 发送完成。
 *
 * i_abort 接事务中止事件，撤销写入和提交脉冲，不产生额外错误响应。
 * 已被 RAM 接收的字节不回滚，发送侧同时接收 abort 负责取消发送。
 * i_rst_n 为异步低有效复位。写数据在 o_rsp_wr_en 有效时才有意义。
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
