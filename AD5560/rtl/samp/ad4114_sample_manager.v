`timescale 1ns/1ps
/*
 * AD4114 多器件采样控制（Verilog-2001）。
 * 单 SPI、每颗独立 CS；每颗固定 8 路差分，Sinc5+Sinc1 49.68 SPS（50Hz 陷波）。
 * 仅负责 ADC 初始化、轮询读取和各通道 skip 过滤，MV/MI 切换由外部处理。
 * SPI 直接从业务状态发起，并由下一个业务状态等待 rx_valid；没有公共 SPI 等待状态。
 * skip_cnt 在 start 时锁存，运行期间不动态调整（通常为 0 或 1）。
 */
module ad4114_sample_manager #(
    parameter integer SYS_CLK_FREQ = 100_000_000,
    parameter integer SPI_CLK_FREQ = 10_000_000,
    parameter integer MAX_ADC      = 16
)(
    input  wire                     i_clk,
    input  wire                     i_rst_n,
    input  wire                     i_start,
    input  wire                     i_stop,
    input  wire [MAX_ADC-1:0]       i_adc_enable_mask,
    input  wire [7:0]               i_skip_cnt,
    output reg                      o_init_done,
    output reg                      o_busy,
    output reg  [MAX_ADC-1:0]       o_init_error,
    output reg                      o_sample_valid,
    output reg  [7:0]               o_sample_adc_id,
    output reg  [2:0]               o_sample_channel,
    output reg  [23:0]              o_sample_data,
    output reg  [MAX_ADC-1:0]       o_spi_cs_n,
    output wire                     o_spi_sck,
    output wire                     o_spi_mosi,
    input  wire                     i_spi_miso
);

// 软件复位后等待 ADC 就绪；检查 DOUT/RDY 前预留片选建立时间。
localparam integer RESET_WAIT       = (SYS_CLK_FREQ / 2000) + 1;        // >=500us
localparam integer RDY_SETUP_CYCLES = (SYS_CLK_FREQ / 20_000_000) + 1; // >=50ns
// 不同 ADC 共用 MISO，切换片选前须让旧器件释放总线（100MHz 下 3 拍=30ns）。
localparam integer CS_SWITCH_CYCLES = (SYS_CLK_FREQ * 3 + 99_999_999) / 100_000_000;

// SPI 请求直接由 ST_PICK / ST_RESET_DELAY / ST_INIT_SEND / ST_READY 发起；
// 后一个业务状态各自等待 rx_valid，并在完成时释放 CS。
localparam [3:0]
    ST_IDLE        = 4'd0,
    ST_PICK        = 4'd1,
    ST_RESET_DELAY = 4'd2,
    ST_ID_CHECK    = 4'd3,
    ST_INIT_SEND   = 4'd4,
    ST_INIT_NEXT   = 4'd5,
    ST_POLL        = 4'd6,
    ST_READY       = 4'd7,
    ST_PROCESS     = 4'd8;

localparam [2:0]
    INIT_CHANNEL = 3'd0,
    INIT_SETUP   = 3'd1,
    INIT_FILTER  = 3'd2,
    INIT_IFMODE  = 3'd3,
    INIT_ADCMODE = 3'd4;

reg [3:0] state;
reg [2:0] init_step;
reg [7:0] adc_index;
reg [4:0] channel_index;
reg [7:0] skip_cfg;
reg [MAX_ADC-1:0] active_mask;
reg [31:0] wait_count;
reg stop_pending;
reg [7:0] last_cs_adc;
reg [7:0] cs_high_count;
// 同一颗 ADC 的连续 SPI 帧不额外等待；切换其它 ADC 时检查全 CS 高电平时间。
wire cs_switch_ready = (adc_index == last_cs_adc) ||
                       (cs_high_count >= CS_SWITCH_CYCLES - 1);
// stop 为单拍或持续电平均可；在途 SPI 帧须执行完毕再释放 CS。
wire stop_request = i_stop || stop_pending;
wire spi_inflight = (state == ST_RESET_DELAY && !spi_cs_reg) ||
                    (state == ST_ID_CHECK) ||
                    (state == ST_INIT_NEXT) ||
                    (state == ST_PROCESS);

reg [63:0] spi_tx;
reg [15:0] spi_len;
reg spi_req;
reg spi_cs_reg;
wire spi_ready;
wire spi_rx_valid;
wire [63:0] spi_rx;
wire spi_cs_dummy;

// 每颗 ADC 固定 8 通道。每次输出有效结果后，只丢弃该通道接下来的 skip_cfg 个结果。
reg [7:0] skip_left [0:MAX_ADC*8-1];
integer k;

// Channel0~7 分别采集 VIN0/VIN1 ~ VIN14/VIN15；Channel8~15 关闭。
// 所有通道选择 Setup0，寄存器内容和原版本保持一致。
wire [15:0] channel_word = {
    (channel_index < 8), 3'b000, 2'b00,
    channel_index[3:0], 1'b0, channel_index[3:0], 1'b1
};

// DATA_STAT=1 时，读回帧的低 32bit 为 24bit 数据加 8bit STATUS。
// 直接使用 spi_rx，避免 rx_valid 当拍读到上一帧的寄存器数据。
wire [2:0] sample_ch = spi_rx[2:0];
wire [10:0] sample_idx = {adc_index, sample_ch};
wire sample_ok = (spi_rx[6:3] == 4'b0000);

spi_master_generic #(
    .SYS_CLK_FREQ   (SYS_CLK_FREQ),
    .SPI_CLK_FREQ   (SPI_CLK_FREQ),
    .MAX_DATA_WIDTH (64),
    .CPOL           (1),
    .CPHA           (1)
) u_spi (
    .i_sys_clk      (i_clk),
    .i_sys_rst_n    (i_rst_n),
    .i_req_valid    (spi_req),
    .o_req_ready    (spi_ready),
    .i_data_len     (spi_len),
    .i_tx_data      (spi_tx),
    .o_rx_valid     (spi_rx_valid),
    .o_rx_data      (spi_rx),
    .i_spi_cs_n     (spi_cs_reg),
    .o_spi_cs       (spi_cs_dummy),
    .o_spi_sck      (o_spi_sck),
    .o_spi_mosi     (o_spi_mosi),
    .i_spi_miso     (i_spi_miso)
);

// 一次只拉低一颗 ADC 的 CS，其余器件保持不选中。
always @(*) begin
    o_spi_cs_n = {MAX_ADC{1'b1}};
    if (!spi_cs_reg && adc_index < MAX_ADC)
        o_spi_cs_n[adc_index] = 1'b0;
end

// 初始化与采样共用一个业务状态机；时序逻辑统一采用非阻塞赋值。
// 发请求时 spi_req / spi_tx / spi_cs_reg 同拍寄存，SPI Master 在下一拍锁存它们。
// spi_req 与 o_sample_valid 均默认每拍清零，发请求的状态仅置位一个时钟；
// 业务状态等待 rx_valid 后再推进，每笔 SPI 事务只有一个 outstanding。
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        state <= ST_IDLE;
        init_step <= INIT_CHANNEL;
        adc_index <= 0;
        channel_index <= 0;
        skip_cfg <= 0;
        active_mask <= 0;
        wait_count <= 0;
        stop_pending <= 0;
        last_cs_adc <= 8'hff;
        cs_high_count <= CS_SWITCH_CYCLES;
        spi_tx <= 0;
        spi_len <= 0;
        spi_req <= 0;
        spi_cs_reg <= 1;
        o_init_done <= 0;
        o_busy <= 0;
        o_init_error <= 0;
        o_sample_valid <= 0;
        o_sample_adc_id <= 0;
        o_sample_channel <= 0;
        o_sample_data <= 0;
        for (k=0; k<MAX_ADC*8; k=k+1)
            skip_left[k] <= 0;
    end else begin
        // 单周期 pulse：每拍默认清零，只有需要发起 SPI 时才置位。
        spi_req <= 1'b0;
        o_sample_valid <= 1'b0;

        // 统计全 CS 高电平时间：仅跨 ADC 切换需要 30ns 间隔。
        if (!spi_cs_reg)
            cs_high_count <= 0;
        else if (cs_high_count < CS_SWITCH_CYCLES)
            cs_high_count <= cs_high_count + 1'b1;

        if (i_stop)
            stop_pending <= 1'b1;

        // 收到停止请求不再发起新帧；若 SPI 正在传输，则等 rx_valid 再停止。
        // 停止期间直接丢弃在途 DATA 结果，避免额外触发外部 MEASOUT 切换。
        if (stop_request && (!spi_inflight || spi_rx_valid)) begin
            spi_cs_reg <= 1;
            stop_pending <= 1'b0;
            o_busy <= 0;
            state <= ST_IDLE;
        end else begin
            case (state)
                ST_IDLE: begin
                    spi_cs_reg <= 1;
                    if (i_start) begin
                        active_mask <= i_adc_enable_mask;
                        skip_cfg <= i_skip_cnt;
                        adc_index <= 0;
                        channel_index <= 0;
                        o_init_done <= 0;
                        o_init_error <= 0;
                        o_busy <= 1;
                        for (k=0; k<MAX_ADC*8; k=k+1)
                            skip_left[k] <= 0;
                        state <= ST_PICK;
                    end
                end

                // 逐颗挑选使能的 ADC，直接提交 64 个 1 作为软件复位帧。
                ST_PICK: begin
                    if (adc_index >= MAX_ADC) begin
                        adc_index <= 0;
                        o_init_done <= 1;
                        state <= ST_POLL;
                    end else if (!active_mask[adc_index]) begin
                        adc_index <= adc_index + 1'b1;
                    end else if (spi_ready && cs_switch_ready) begin
                        spi_tx <= 64'hFFFFFFFFFFFFFFFF;
                        spi_len <= 16'd64;
                        spi_cs_reg <= 0;
                        last_cs_adc <= adc_index;
                        spi_req <= 1;
                        wait_count <= 0;
                        state <= ST_RESET_DELAY;
                    end
                end

                // 先等待复位 SPI 结束，再释放 CS 并等待 >=500us。
                // 用实际 CS 状态区分等待 SPI 和等待复位恢复，无需另加状态。
                ST_RESET_DELAY: begin
                    if (!spi_cs_reg) begin
                        if (spi_rx_valid) begin
                            spi_cs_reg <= 1;
                            wait_count <= 0;
                        end
                    end else if (wait_count < RESET_WAIT) begin
                        wait_count <= wait_count + 1'b1;
                    end else if (spi_ready) begin
                        // 延时完成后直接读 ID，随后在 ST_ID_CHECK 等回读。
                        spi_tx <= {40'd0, 8'h47, 16'hFFFF};
                        spi_len <= 16'd24;
                        spi_cs_reg <= 0;
                        spi_req <= 1;
                        state <= ST_ID_CHECK;
                    end
                end

                ST_ID_CHECK: begin
                    if (spi_rx_valid) begin
                        spi_cs_reg <= 1;
                        if (spi_rx[15:4] != 12'h30D) begin
                            // ID 不匹配则记录当前 ADC 错误并跳到下一颗。
                            o_init_error[adc_index] <= 1'b1;
                            adc_index <= adc_index + 1'b1;
                            state <= ST_PICK;
                        end else begin
                            channel_index <= 0;
                            init_step <= INIT_CHANNEL;
                            state <= ST_INIT_SEND;
                        end
                    end
                end

                // 根据 init_step 写 Channel0~15、Setup0、Filter0、Interface、ADC Mode。
                // 启动 SPI 后进入 ST_INIT_NEXT，直接在那里等待本次写帧完成。
                ST_INIT_SEND: begin
                    if (spi_ready) begin
                        case (init_step)
                            INIT_CHANNEL: spi_tx <= {40'd0, (8'h10 + {3'd0, channel_index}), channel_word};
                            INIT_SETUP:   spi_tx <= {40'd0, 8'h20, 16'h1F20};
                            // 普通 Sinc5+Sinc1，49.68SPS，20.13ms 建立时间，50Hz 陷波。
                            INIT_FILTER:  spi_tx <= {40'd0, 8'h28, 16'h0510};
                            // DATA_STAT=1，CRC=0。
                            INIT_IFMODE:  spi_tx <= {40'd0, 8'h02, 16'h0140};
                            // 连续转换，内部时钟。
                            INIT_ADCMODE: spi_tx <= {40'd0, 8'h01, 16'h8000};
                            default:      spi_tx <= 64'd0;
                        endcase
                        spi_len <= 16'd24;
                        spi_cs_reg <= 0;
                        spi_req <= 1;
                        state <= ST_INIT_NEXT;
                    end
                end

                ST_INIT_NEXT: begin
                    if (spi_rx_valid) begin
                        spi_cs_reg <= 1;
                        if (init_step == INIT_CHANNEL) begin
                            if (channel_index < 15)
                                channel_index <= channel_index + 1'b1;
                            else
                                init_step <= INIT_SETUP;
                            state <= ST_INIT_SEND;
                        end else if (init_step == INIT_ADCMODE) begin
                            adc_index <= adc_index + 1'b1;
                            state <= ST_PICK;
                        end else begin
                            init_step <= init_step + 1'b1;
                            state <= ST_INIT_SEND;
                        end
                    end
                end

                // 正常轮询仅处理使能且 ID 检查通过的 ADC。
                ST_POLL: begin
                    if (adc_index >= MAX_ADC)
                        adc_index <= 0;
                    else if (!active_mask[adc_index] || o_init_error[adc_index])
                        adc_index <= adc_index + 1'b1;
                    else if (cs_switch_ready) begin
                        spi_cs_reg <= 0;
                        last_cs_adc <= adc_index;
                        wait_count <= 0;
                        state <= ST_READY;
                    end
                end

                // DOUT/RDY 与 MISO 共用：CS 拉低后先等待引脚有效，再判断 READY。
                // 若 READY=0，直接发起 40bit 读取；否则跳过此 ADC。
                ST_READY: begin
                    if (wait_count < RDY_SETUP_CYCLES) begin
                        wait_count <= wait_count + 1'b1;
                    end else if (!i_spi_miso) begin
                        if (spi_ready) begin
                            spi_tx <= {24'd0, 8'h44, 32'hFFFFFFFF};
                            spi_len <= 16'd40;
                            spi_req <= 1;
                            state <= ST_PROCESS;
                        end
                    end else begin
                        spi_cs_reg <= 1;
                        adc_index <= adc_index + 1'b1;
                        state <= ST_POLL;
                    end
                end

                // 直接在数据读取完成时校验 STATUS，按通道独立过滤 skip 点。
                // 采样有效结果输出一拍，外部据 ADC_ID/CH 自行切换 AD5560 的 MV/MI。
                ST_PROCESS: begin
                    if (spi_rx_valid) begin
                        spi_cs_reg <= 1;
                        if (sample_ok) begin
                            if (skip_left[sample_idx] != 0) begin
                                skip_left[sample_idx] <= skip_left[sample_idx] - 1'b1;
                            end else begin
                                o_sample_valid <= 1;
                                o_sample_adc_id <= adc_index;
                                o_sample_channel <= sample_ch;
                                o_sample_data <= spi_rx[31:8];
                                skip_left[sample_idx] <= skip_cfg;
                            end
                        end
                        adc_index <= adc_index + 1'b1;
                        state <= ST_POLL;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
end

endmodule
