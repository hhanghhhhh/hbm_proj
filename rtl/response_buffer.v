`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * 响应接口选择模块，仅作组合 MUX，不包含 Response RAM。
 *
 * 正常响应按 Dispatcher 的 i_active_module 选择参数或控制业务接口。
 * 错误响应源的 i_error_rsp_wr_en 或 i_error_rsp_valid 有效时，优先
 * 选择错误源的整组接口，保证错误 Payload 写入和最终提交都能通过。
 * 这里使用的是错误响应生成器的输出，不是业务模块的 error_valid。
 *
 * 响应源先逐字节写入 Payload，再产生单周期 rsp_valid；本模块原样
 * 转发五个响应信号，不增加寄存级，也不解析 STATUS、长度或数据。
 * 输出连接 TX Frame Builder，Response RAM 位于该发送模块内部。
 *
 * 系统保证严格单事务，正常响应和错误响应不会同时提交。错误响应
 * 写入中的空拍可以恢复正常源选择，此时正常源不得产生写入或提交。
 * 正常事务结束后 active_module 可以保留，响应源撤销 wr_en/valid
 * 即可停止输出动作；没有选中正常模块时，整组输出为 0。
 *
 * 本模块没有时钟、复位、abort、frame_done 或 tx_done 接口。
 * 复位和事务中止由响应源及发送模块处理，不在本模块增加状态。
 * 新增业务时，增加一组输入接口和对应的 active_module 选择分支。
 */
module response_buffer (
    input  wire [1:0]  i_active_module,

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
        end else begin
            o_rsp_wr_en   = 1'b0;
            o_rsp_wr_addr = 11'd0;
            o_rsp_wr_data = 8'd0;
            o_rsp_length  = 16'd0;
            o_rsp_valid   = 1'b0;
        end
    end

endmodule
