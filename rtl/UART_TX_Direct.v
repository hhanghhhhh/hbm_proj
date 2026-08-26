/*
Module Name : UART_TX_Direct
Description : Ultra-High Precision Native-Clock UART Transmitter
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