/*
 * 模块说明
 *
 * 功能：
 * - 直接用系统时钟计数发送 8N1 UART 字节；不包含多字节缓存、帧级完成
 *   指示或 RS485 方向控制。
 *
 * 关键约束：
 * - 每个位固定使用 SYS_CLK_FREQ/BAUD_RATE 个时钟周期，除法余数被截断，
 *   不进行分数波特率补偿；BIT_CYCLES 必须为 16 位计数器可表示的正整数。
 *
 * 特殊行为：
 * - o_tx_ready 表示 UART 物理发送完全空闲，在起始位、8 个数据位和停止位
 *   的整个发送期间保持为 0，不表示 FIFO 可继续写入。
 * - 非空闲期间输入字节不会被采样或排队。
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