/*
 * 模块说明
 *
 * 功能：
 * - 通用 SPI Master，支持 CPOL/CPHA 四种模式和可变传输位数。
 * - 用户数据按低位右对齐输入，模块内部转换为 MSB first 串行发送。
 *
 * 关键约束：
 * - i_req_valid / o_req_ready 只负责启动一帧 SPI 传输，接收完成由 o_rx_valid 单周期指示。
 * - CS 不由本模块状态机自动生成，i_spi_cs_n 由上层控制并直接输出，便于上层组合多帧事务。
 * - SCK 由系统时钟分频产生；要求 SYS_CLK_FREQ 不低于 2 × SPI_CLK_FREQ。
 */

module spi_master_generic #(
    parameter SYS_CLK_FREQ   = 100_000_000, // 系统时钟频率 Hz
    parameter SPI_CLK_FREQ   = 1_000_000,   // 目标 SPI SCK 频率 Hz
    parameter MAX_DATA_WIDTH = 32,          // 单帧最大位数
    parameter CPOL           = 0,           // SCK 空闲电平 0=低，1=高
    parameter CPHA           = 0            // 0=首边沿采样，1=次边沿采样
)(
    input  wire                         i_sys_clk,
    input  wire                         i_sys_rst_n,
    
    // 上层请求接口
    input  wire                         i_req_valid,      // 请求发送一帧
    output wire                         o_req_ready,      // IDLE 时可接受新请求
    input  wire [15:0]                  i_data_len,       // 本帧有效位数
    input  wire [MAX_DATA_WIDTH-1:0]    i_tx_data,        // 发送数据，低位右对齐
    
    output reg                          o_rx_valid,       // 接收完成单周期脉冲
    output reg  [MAX_DATA_WIDTH-1:0]    o_rx_data,        // 接收数据，低位右对齐
    
    input  wire                         i_spi_cs_n,       // 上层 CS 控制，模块内不自动改变
    
    // SPI 物理接口
    output wire                         o_spi_cs,
    output reg                          o_spi_sck,
    output reg                          o_spi_mosi,
    input  wire                         i_spi_miso
);

//-------------------------------------------------------------------
// SCK 半周期分频：每个 sck_tick 翻转一次 SCK，因此 tick 频率为 2 × SPI_CLK。
//-------------------------------------------------------------------
localparam CLK_DIV_TMP = SYS_CLK_FREQ / (SPI_CLK_FREQ * 2);
// 分频比最小取 1；系统设计应保证 SYS_CLK_FREQ >= 2 × SPI_CLK_FREQ。
localparam DIV_RATIO   = (CLK_DIV_TMP > 0) ? CLK_DIV_TMP : 1;

reg [15:0]  div_cnt;
wire        sck_tick;

//-------------------------------------------------------------------
// FSM 与移位寄存器
//-------------------------------------------------------------------
localparam STATE_IDLE = 2'd0;
localparam STATE_WORK = 2'd1;
localparam STATE_DONE = 2'd2;

reg [1:0]                   state;
reg [15:0]                  phase_cnt;      // 每个 SPI bit 对应两个 SCK phase
reg [15:0]                  current_len;    // 请求握手时锁存本帧位数
reg [MAX_DATA_WIDTH-1:0]    tx_shifter;     // MSB first 发送移位寄存器
reg [MAX_DATA_WIDTH-1:0]    rx_shifter;     // 采样后自然形成低位右对齐结果

//-------------------------------------------------------------------
// CPHA 决定每个 bit 的两个 phase 中，哪个 phase 采样 MISO、哪个 phase 更新 MOSI。
// CPHA=0：第一个边沿采样；CPHA=1：第一个边沿更新数据、第二个边沿采样。
wire sample_en = (CPHA == 0) ? (phase_cnt[0] == 1'b0) : (phase_cnt[0] == 1'b1);
wire shift_en  = (CPHA == 0) ? (phase_cnt[0] == 1'b1) : (phase_cnt[0] == 1'b0);

// 仅在 WORK 中运行分频计数，离开传输状态后立即清零，保证每帧从完整半周期开始。
always @(posedge i_sys_clk or negedge i_sys_rst_n) begin
    if (!i_sys_rst_n) begin
        div_cnt <= 16'd0;
    end else if (state == STATE_WORK) begin
        if (div_cnt == DIV_RATIO - 1)
            div_cnt <= 16'd0;
        else
            div_cnt <= div_cnt + 16'd1;
    end else begin
        div_cnt <= 16'd0;
    end
end
assign sck_tick = (state == STATE_WORK) && (div_cnt == DIV_RATIO - 1);

//-------------------------------------------------------------------
// 主状态机：锁存请求 -> 按 phase 产生 SCK/移位 -> 返回接收结果
//-------------------------------------------------------------------
always @(posedge i_sys_clk or negedge i_sys_rst_n) begin
    if (!i_sys_rst_n) begin
        state       <= STATE_IDLE;
        o_spi_sck   <= CPOL[0];
        o_spi_mosi  <= 1'b0;
        o_rx_valid  <= 1'b0;
        o_rx_data   <= {MAX_DATA_WIDTH{1'b0}};
        phase_cnt   <= 16'd0;
        current_len <= 16'd0;
        tx_shifter  <= {MAX_DATA_WIDTH{1'b0}};
        rx_shifter  <= {MAX_DATA_WIDTH{1'b0}};
    end 
    else begin
        case (state)
            // IDLE：接受新请求并锁存本帧长度/数据；进入 WORK 前准备首个 MOSI bit。
            STATE_IDLE: begin
                o_rx_valid <= 1'b0;
                o_spi_sck  <= CPOL[0];
                
                if (i_req_valid) begin
                    state       <= STATE_WORK;
                    current_len <= i_data_len;
                    phase_cnt   <= 16'd0;
                    
                    // 接口数据按低位右对齐；内部左移到 MSB 端，后续统一按 MSB first 发送。
                    tx_shifter  <= i_tx_data << (MAX_DATA_WIDTH - i_data_len);
                    
                    // CPHA=0 的首个边沿就是采样边沿，因此进入 WORK 前必须先把首 bit 放到 MOSI。
                    if (CPHA == 0) begin
                        o_spi_mosi <= i_tx_data[i_data_len - 16'd1]; 
                    end
                end
            end
            
            // WORK：每个 sck_tick 翻转一次 SCK，并按 CPHA 对应 phase 完成采样或移位。
            STATE_WORK: begin
                if (sck_tick) begin
                    phase_cnt <= phase_cnt + 16'd1;
                    
                    // 一个 tick 对应半个 SPI 周期。
                    o_spi_sck <= ~o_spi_sck;
                    
                    // 每次采样把新 bit 移入最低位；完成 N 次后有效数据自然位于低 N bit。
                    if (sample_en) begin
                        rx_shifter <= {rx_shifter[MAX_DATA_WIDTH-2:0], i_spi_miso};
                    end
                    
                    // 更新 MOSI。CPHA=1 的第一个 phase 只送出首 bit，尚不能先移位。
                    if (shift_en) begin
                        if (CPHA == 1 && phase_cnt == 16'd0) begin
                            o_spi_mosi <= tx_shifter[MAX_DATA_WIDTH-1];
                        end else begin
                            // 后续 phase 左移一位，并提前送出下一待发送 bit。
                            tx_shifter <= {tx_shifter[MAX_DATA_WIDTH-2:0], 1'b0};
                            o_spi_mosi <= tx_shifter[MAX_DATA_WIDTH-2];
                        end
                    end
                    
                    // 每个 SPI bit 占两个 phase；最后一个 phase 完成后结束本帧。
                    if (phase_cnt == (current_len << 1) - 16'd1) begin
                        state <= STATE_DONE;
                    end
                end
            end
            
            // DONE：恢复 SCK 空闲电平，发布接收结果；o_rx_valid 仅保持一个系统时钟。
            STATE_DONE: begin
                o_spi_sck  <= CPOL[0];
                o_rx_valid <= 1'b1;
                o_rx_data  <= rx_shifter;
                state      <= STATE_IDLE;
            end
            
            default: state <= STATE_IDLE;
        endcase
    end
end

//-------------------------------------------------------------------
// ready 仅在 IDLE 有效；CS 完全由上层控制，本模块只做直通。
//-------------------------------------------------------------------
assign o_req_ready = (state == STATE_IDLE);
assign o_spi_cs    = i_spi_cs_n;

endmodule