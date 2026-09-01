/*
 * Module Contract
 *
 * 模块职责：
 * - 将并行字节转换为原生系统时钟计数的 8N1 UART 串行波形。
 * - 提供空闲 ready 指示，使上游仅在发送器空闲时提交一个字节。
 * - 不负责：缓存多字节、计算波特率误差、生成帧级完成事件或控制 RS485 方向。
 *
 * 输入事务：
 * - o_tx_ready=1 时，i_tx_valid=1 的上升沿采样 i_tx_data 并开始发送。
 * - 非空闲期间 o_tx_ready=0，i_tx_valid 和 i_tx_data 均不会被采样或排队。
 *
 * 输出事务：
 * - 每次事务发送 1 个低电平起始位、8 个最低位优先数据位和 1 个高电平停止位。
 * - o_tx_ready 在整个起始位、数据位和停止位期间保持为 0，结束后重新置 1。
 * - 空闲时 o_uart_tx 保持高电平；模块不另设 tx_done 脉冲。
 *
 * 关键时序：
 * - 每个串行位持续 BIT_CYCLES=SYS_CLK_FREQ/BAUD_RATE 个 i_sys_clk 周期。
 * - 参数整除产生的余数被截断；模块不进行分数波特率补偿。
 *
 * 异常与恢复：
 * - reset：异步低有效，立即返回空闲、拉高 o_uart_tx 并丢弃在途字节。
 * - 模块没有 abort、超时或发送错误接口。
 *
 * 使用约束：
 * - SYS_CLK_FREQ/BAUD_RATE 必须得到可由 16 位计数器表示的正整数 BIT_CYCLES。
 * - 上游只有在 o_tx_ready=1 时提交 i_tx_valid，且一次只提交一个字节。
 */

module UART_TX_Direct #(
    parameter SYS_CLK_FREQ = 100_000_000,
    parameter BAUD_RATE    = 5_000_000
)(
    input  wire         i_sys_clk,
    input  wire         i_sys_rst_n,
    
    input  wire         i_tx_valid,
    output wire         o_tx_ready,
    input  wire [7:0]   i_tx_data,
    
    output reg          o_uart_tx
);

localparam BIT_CYCLES = SYS_CLK_FREQ / BAUD_RATE;

localparam STATE_IDLE  = 2'd0;
localparam STATE_START = 2'd1;
localparam STATE_DATA  = 2'd2;
localparam STATE_STOP  = 2'd3;

reg [1:0]  state;
reg [15:0] clk_cnt;
reg [2:0]  bit_cnt;
reg [7:0]  tx_shifter;

assign o_tx_ready = (state == STATE_IDLE);

always @(posedge i_sys_clk or negedge i_sys_rst_n) begin
    if (!i_sys_rst_n) begin
        state      <= STATE_IDLE;
        clk_cnt    <= 16'd0;
        bit_cnt    <= 3'd0;
        tx_shifter <= 8'd0;
        o_uart_tx  <= 1'b1;
    end 
    else begin
        case (state)
            STATE_IDLE: begin
                o_uart_tx <= 1'b1;
                clk_cnt   <= 16'd0;
                if (i_tx_valid) begin
                    state      <= STATE_START;
                    tx_shifter <= i_tx_data;
                end
            end
            
            STATE_START, STATE_DATA, STATE_STOP: begin
                clk_cnt <= clk_cnt + 16'd1;
                
                // --- 1. 时钟周期开始时的动作 (沿对齐) ---
                if (clk_cnt == 16'd0) begin
                    if (state == STATE_START)
                        o_uart_tx <= 1'b0;
                    else if (state == STATE_DATA)
                        o_uart_tx <= tx_shifter[0];
                    else if (state == STATE_STOP)
                        o_uart_tx <= 1'b1;
                end
                
                // --- 2. 周期计数与跳转 ---
                if (clk_cnt == BIT_CYCLES - 16'd1) begin
                    clk_cnt <= 16'd0; // Bit周期完结
                    
                    if (state == STATE_START) begin
                        state   <= STATE_DATA;
                        bit_cnt <= 3'd0;
                    end
                    else if (state == STATE_DATA) begin
                        tx_shifter <= {1'b0, tx_shifter[7:1]};
                        if (bit_cnt == 3'd7) state <= STATE_STOP;
                        else bit_cnt <= bit_cnt + 3'd1;
                    end
                    else if (state == STATE_STOP) begin
                        state <= STATE_IDLE;
                    end
                end
            end
            
            default: state <= STATE_IDLE;
        endcase
    end
end

endmodule