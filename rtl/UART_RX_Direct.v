/*
 * Module Contract
 *
 * 模块职责：
 * - 将异步 8N1 UART 串行输入转换为并行字节和接收事件。
 * - 对每个串行位进行三点多数表决，并拒绝未形成有效起始位的下降沿毛刺。
 * - 检查停止位并报告帧格式错误。
 * - 不负责：缓存连续字节、协议组帧、校验 CRC 或恢复错误字节。
 *
 * 输入事务：
 * - 同步后的 i_uart_rx 下降沿启动候选字节接收；起始位多数表决为 0 才继续。
 * - 有效起始位后依次接收 8 个最低位优先数据位和 1 个停止位。
 * - 接收期间不会识别或排队新的起始沿。
 *
 * 输出事务：
 * - 停止位表决为 1 时更新 o_rx_data，并产生 1clk 的 o_rx_valid。
 * - 停止位表决为 0 时产生 1clk 的 o_rx_err，不产生 o_rx_valid。
 * - 起始位毛刺被静默丢弃，不产生 o_rx_valid 或 o_rx_err。
 *
 * 关键时序：
 * - 输入先经过多级同步；每个位在中点附近三个时刻采样并多数表决。
 * - 每个位周期为 BIT_CYCLES=SYS_CLK_FREQ/BAUD_RATE 个 i_sys_clk 周期。
 * - 停止位完成表决后提前回到空闲，以便接收紧邻的下一起始位。
 *
 * 异常与恢复：
 * - reset：异步低有效，回到空闲，清除数据与事件输出并将同步链置为高电平。
 * - 帧错误后自动回到空闲；模块没有 abort 或超时接口。
 *
 * 使用约束：
 * - SYS_CLK_FREQ/BAUD_RATE 必须满足三点采样位置有效且周期可由 16 位计数器表示。
 * - i_uart_rx 必须为空闲高电平的 8N1 信号；参数整除余数不会进行分数补偿。
 */

module UART_RX_Direct #(
    parameter SYS_CLK_FREQ = 100_000_000, 
    parameter BAUD_RATE    = 5_000_000
)(
    input  wire         i_sys_clk,
    input  wire         i_sys_rst_n,
    
    input  wire         i_uart_rx,
    
    output reg          o_rx_valid,
    output reg  [7:0]   o_rx_data,
    output reg          o_rx_err
);

//-------------------------------------------------------------------
// 1. Core Timing Calculations (Direct Counter)
//-------------------------------------------------------------------
localparam BIT_CYCLES = SYS_CLK_FREQ / BAUD_RATE;
localparam MID_PT     = BIT_CYCLES / 2;

// 动态计算三次采样的间距 (Sample Gap)
// 如果波特率极高(BIT_CYCLES很小)，间距最小为1个时钟；
// 如果波特率低，间距自动拉开(约为周期的1/16)，实现大范围抗宽脉冲干扰。
localparam SMP_GAP    = (BIT_CYCLES > 15) ? (BIT_CYCLES / 16) : 1;

// 三个采样点
localparam SMP_PT1    = MID_PT - SMP_GAP - 1;
localparam SMP_PT2    = MID_PT - 1;
localparam SMP_PT3    = MID_PT + SMP_GAP - 1;

// 结算点与提前退出点
localparam EVAL_PT    = SMP_PT3 + 1;           // 采样完毕后立马结算
localparam EXIT_PT    = EVAL_PT + 1;           // Stop位过了 75% 即可提前退出，拥抱下一个Start

//-------------------------------------------------------------------
// 2. Input Synchronization
//-------------------------------------------------------------------
reg rx_s1, rx_s2, rx_s3;
always @(posedge i_sys_clk or negedge i_sys_rst_n) begin
    if (!i_sys_rst_n) begin
        {rx_s3, rx_s2, rx_s1} <= 3'b111;
    end else begin
        rx_s1 <= i_uart_rx;
        rx_s2 <= rx_s1;
        rx_s3 <= rx_s2;
    end
end
wire rx_falling = (rx_s3 == 1'b1) && (rx_s2 == 1'b0);

//-------------------------------------------------------------------
// 3. FSM States & Registers
//-------------------------------------------------------------------
localparam STATE_IDLE  = 2'd0;
localparam STATE_START = 2'd1;
localparam STATE_DATA  = 2'd2;
localparam STATE_STOP  = 2'd3;

reg [1:0]  state;
reg [15:0] clk_cnt;
reg [2:0]  bit_cnt;
reg [7:0]  rx_shifter;

reg smp_1, smp_2, smp_3;
reg bit_val;

//-------------------------------------------------------------------
// 4. Main State Machine
//-------------------------------------------------------------------
always @(posedge i_sys_clk or negedge i_sys_rst_n) begin
    if (!i_sys_rst_n) begin
        state      <= STATE_IDLE;
        clk_cnt    <= 16'd0;
        bit_cnt    <= 3'd0;
        rx_shifter <= 8'd0;
        o_rx_valid <= 1'b0;
        o_rx_data  <= 8'd0;
        o_rx_err   <= 1'b0;
        smp_1 <= 0; smp_2 <= 0; smp_3 <= 0; bit_val <= 0;
    end 
    else begin
        o_rx_valid <= 1'b0;
        o_rx_err   <= 1'b0;

        case (state)
            STATE_IDLE: begin
                if (rx_falling) begin
                    state   <= STATE_START;
                    clk_cnt <= 16'd0;  // 绝对的同步清零时刻
                end
            end
            
            STATE_START, STATE_DATA, STATE_STOP: begin
                clk_cnt <= clk_cnt + 16'd1;
                
                // --- 1. 三点分离采样 ---
                if (clk_cnt == SMP_PT1) smp_1 <= rx_s2;
                if (clk_cnt == SMP_PT2) smp_2 <= rx_s2;
                if (clk_cnt == SMP_PT3) smp_3 <= rx_s2;
                
                // --- 2. 多数表决结算 ---
                if (clk_cnt == EVAL_PT) begin
                    bit_val <= (smp_1 & smp_2) | (smp_2 & smp_3) | (smp_1 & smp_3);
                end
                
                // --- 3. 状态专属动作 ---
                if (state == STATE_START) begin
                    if (clk_cnt == EVAL_PT + 1) begin
                        // 验证起始位，如果不是 0，说明是尖峰毛刺，立即流产！
                        if (bit_val == 1'b1) state <= STATE_IDLE; 
                    end
                end
                else if (state == STATE_STOP) begin
                    if (clk_cnt == EVAL_PT + 1) begin
                        if (bit_val == 1'b0) o_rx_err <= 1'b1;  // Stop位不是1，报帧错
                        else begin
                            o_rx_data  <= rx_shifter;
                            o_rx_valid <= 1'b1; // 接收成功脉冲
                        end
                    end
                    // 核心特性：Early Exit (提前退出)，防背靠背相位漂移
                    if (clk_cnt == EXIT_PT) begin
                        state <= STATE_IDLE;
                    end
                end
                
                // --- 4. 周期完结与跳转 ---
                // 不管在哪个状态，满一个 BIT_CYCLES 准时进入下一 Bit (除了 Stop位提前退出)
                if (clk_cnt == BIT_CYCLES - 16'd1) begin
                    clk_cnt <= 16'd0; // 内部清零，吃掉截断误差
                    
                    if (state == STATE_START) begin
                        state   <= STATE_DATA;
                        bit_cnt <= 3'd0;
                    end
                    else if (state == STATE_DATA) begin
                        rx_shifter <= {bit_val, rx_shifter[7:1]};
                        if (bit_cnt == 3'd7) state <= STATE_STOP;
                        else bit_cnt <= bit_cnt + 3'd1;
                    end
                end
            end
            
            default: state <= STATE_IDLE;
        endcase
    end
end

endmodule