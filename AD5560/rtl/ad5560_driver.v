`timescale 1ns/1ps

/*
 * 模块说明
 *
 * 功能：
 * - 控制一条 AD5560 SPI BUS 上的 16 颗器件，完成寄存器读写事务。
 * - 封装 24-bit SPI 帧、两帧 Readback、BUSY 等待及 timeout。
 *
 * 关键约束：
 * - i_cmd_rw：0=Write，1=Read；Read Request 的 Data 固定为 0。
 * - 每次事务只允许一路 SYNC_n 拉低，DEVICE_ID 在命令握手时锁存。
 * - Write 握手后独立执行；Read 仅在 o_rsp_valid 时返回有效数据。
 * - BUSY 为低有效；timeout 后 o_bus_fault 保持置位，直到 clear/reset。
 * - 已提交给 SPI Master 的事务不会被上层撤销。
 */

module ad5560_driver #(
    parameter SYS_CLK_FREQ    = 100_000_000,
    parameter SPI_CLK_FREQ    = 10_000_000,
    parameter BUSY_TIMEOUT_US = 5
)(
    input  wire         i_clk,
    input  wire         i_rst_n,

    // 公共命令接口
    input  wire         i_cmd_valid,
    output wire         o_cmd_ready,
    input  wire         i_cmd_rw,
    input  wire [3:0]   i_cmd_device_id,
    input  wire [6:0]   i_cmd_reg_addr,
    input  wire [15:0]  i_cmd_wr_data,

    // Read response
    output reg          o_rsp_valid,
    output reg  [15:0]  o_rsp_rd_data,

    // Driver fault
    output reg          o_bus_fault,
    input  wire         i_bus_fault_clear,

    // AD5560 physical interface
    output reg  [15:0]  o_sync_n,
    input  wire         i_busy_n,
    output wire         o_spi_sck,
    output wire         o_spi_mosi,
    input  wire         i_spi_miso
);

//-------------------------------------------------------------------
// AD5560 时序保护参数：统一换算成 i_clk 周期，FSM 只按周期计数。
//-------------------------------------------------------------------
// SYNC 拉低到首个 SCLK、末个 SCLK 到 SYNC 拉高，以及读回后的 SDO 释放均预留 >= 50 ns。
localparam integer CS_GUARD_CYCLES =
    (SYS_CLK_FREQ + 20_000_000 - 1) / 20_000_000;

// WRITE 完成后先等待 >= 100 ns，再检查 BUSY，避开 BUSY 最迟拉低的响应窗口。
localparam integer BUSY_GUARD_CYCLES =
    (SYS_CLK_FREQ + 10_000_000 - 1) / 10_000_000;

// READ 两帧之间保持 SYNC high >= 500 ns，再发送第二帧 NOP 取得 readback。
localparam integer READ_GAP_CYCLES =
    (SYS_CLK_FREQ + 2_000_000 - 1) / 2_000_000;

localparam integer BUSY_TIMEOUT_CYCLES =
    ((SYS_CLK_FREQ * BUSY_TIMEOUT_US) + 1_000_000 - 1) / 1_000_000;

//-------------------------------------------------------------------
// FSM
//-------------------------------------------------------------------
localparam [3:0] ST_IDLE             = 4'd0;
localparam [3:0] ST_CS_SETUP_1       = 4'd1;
localparam [3:0] ST_SPI_REQ_1        = 4'd2;
localparam [3:0] ST_SPI_WAIT_1       = 4'd3;
localparam [3:0] ST_CS_HOLD_1        = 4'd4;
localparam [3:0] ST_WRITE_BUSY_GUARD = 4'd5;
localparam [3:0] ST_WRITE_BUSY_WAIT  = 4'd6;
localparam [3:0] ST_READ_GAP         = 4'd7;
localparam [3:0] ST_CS_SETUP_2       = 4'd8;
localparam [3:0] ST_SPI_REQ_2        = 4'd9;
localparam [3:0] ST_SPI_WAIT_2       = 4'd10;
localparam [3:0] ST_CS_HOLD_2        = 4'd11;
localparam [3:0] ST_READ_SDO_GUARD   = 4'd12;
localparam [3:0] ST_FAULT            = 4'd13;

reg [3:0] state;

reg         cmd_rw_reg;
reg [3:0]   device_id_reg;

reg [31:0]  timing_cnt;
reg [31:0]  timeout_cnt;

reg         spi_req_valid;
wire        spi_req_ready;
reg [23:0]  spi_tx_data;
wire        spi_rx_valid;
wire [23:0] spi_rx_data;
reg         spi_cs_n_reg;
wire        spi_cs_n;

reg         busy_meta;
reg         busy_sync;

assign o_cmd_ready = (state == ST_IDLE) && !o_bus_fault;

//-------------------------------------------------------------------
// External asynchronous input synchronization
//-------------------------------------------------------------------
// BUSY 为异步状态输入，进入 i_clk 域后先经过两级寄存器同步。
// MISO 不做普通两拍同步：SPI Master 按 SCLK 指定采样边沿直接寄存数据，
// 若在前级增加两拍会额外引入约 20 ns 延迟，破坏 10 MHz readback 时序裕量。
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        busy_meta <= 1'b1;
        busy_sync <= 1'b1;
    end
    else begin
        busy_meta <= i_busy_n;
        busy_sync <= busy_meta;
    end
end

//-------------------------------------------------------------------
// 16 路 SYNC 映射：SPI Master 只产生一个内部 CS，由握手时锁存的 DEVICE_ID 译码到对应器件。
//-------------------------------------------------------------------
always @(*) begin
    o_sync_n = 16'hFFFF;
    if (!spi_cs_n)
        o_sync_n[device_id_reg] = 1'b0;
end

//-------------------------------------------------------------------
// SPI Master 只负责单个 24-bit 帧；AD5560 的双帧 READ、SYNC 间隔和 BUSY 语义由本 Driver 组织。
//-------------------------------------------------------------------
spi_master_generic #(
    .SYS_CLK_FREQ   (SYS_CLK_FREQ),
    .SPI_CLK_FREQ   (SPI_CLK_FREQ),
    .MAX_DATA_WIDTH (24),
    .CPOL           (0),
    .CPHA           (1)
) u_spi_master (
    .i_sys_clk      (i_clk),
    .i_sys_rst_n    (i_rst_n),
    .i_req_valid    (spi_req_valid),
    .o_req_ready    (spi_req_ready),
    .i_data_len     (16'd24),
    .i_tx_data      (spi_tx_data),
    .o_rx_valid     (spi_rx_valid),
    .o_rx_data      (spi_rx_data),
    .i_spi_cs_n     (spi_cs_n_reg),
    .o_spi_cs       (spi_cs_n),
    .o_spi_sck      (o_spi_sck),
    .o_spi_mosi     (o_spi_mosi),
    // SDO 为 SPI 同步返回数据，由 SPI Master 在规定采样边沿直接寄存。
    .i_spi_miso     (i_spi_miso)
);

//-------------------------------------------------------------------
// 主流程：锁存命令 -> 执行首帧 -> WRITE 等 BUSY / READ 发 NOP 第二帧 -> 完成或进入 FAULT。
//-------------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        state          <= ST_IDLE;
        cmd_rw_reg     <= 1'b0;
        device_id_reg  <= 4'd0;
        timing_cnt     <= 32'd0;
        timeout_cnt    <= 32'd0;
        spi_req_valid  <= 1'b0;
        spi_tx_data    <= 24'd0;
        spi_cs_n_reg   <= 1'b1;
        o_rsp_valid    <= 1'b0;
        o_rsp_rd_data  <= 16'd0;
        o_bus_fault    <= 1'b0;
    end
    else if (i_bus_fault_clear && o_bus_fault) begin
        // fault clear 只恢复本 BUS Driver 到 IDLE；系统级 fault 是否解除由上层单独决定。
        state          <= ST_IDLE;
        timing_cnt     <= 32'd0;
        timeout_cnt    <= 32'd0;
        spi_req_valid  <= 1'b0;
        spi_cs_n_reg   <= 1'b1;
        o_rsp_valid    <= 1'b0;
        o_bus_fault    <= 1'b0;
    end
    else begin
        // pulse 类输出默认清零。
        o_rsp_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                spi_req_valid <= 1'b0;
                spi_cs_n_reg  <= 1'b1;
                timing_cnt    <= 32'd0;
                timeout_cnt   <= 32'd0;

                if (i_cmd_valid && o_cmd_ready) begin
                    cmd_rw_reg    <= i_cmd_rw;
                    device_id_reg <= i_cmd_device_id;

                    // valid/ready 握手时锁存整笔事务；之后上层字段变化不会影响当前 SPI 帧。READ request 的 Data 固定为 0。
                    if (i_cmd_rw)
                        spi_tx_data <= {1'b1, i_cmd_reg_addr, 16'h0000};
                    else
                        spi_tx_data <= {1'b0, i_cmd_reg_addr, i_cmd_wr_data};

                    spi_cs_n_reg <= 1'b0;
                    timing_cnt   <= 32'd0;
                    state        <= ST_CS_SETUP_1;
                end
            end

            ST_CS_SETUP_1: begin
                if (timing_cnt >= CS_GUARD_CYCLES - 1) begin
                    timing_cnt    <= 32'd0;
                    spi_req_valid <= 1'b1;
                    state         <= ST_SPI_REQ_1;
                end
                else begin
                    timing_cnt <= timing_cnt + 32'd1;
                end
            end

            ST_SPI_REQ_1: begin
                if (spi_req_valid && spi_req_ready) begin
                    spi_req_valid <= 1'b0;
                    state         <= ST_SPI_WAIT_1;
                end
            end

            ST_SPI_WAIT_1: begin
                if (spi_rx_valid) begin
                    timing_cnt <= 32'd0;
                    state      <= ST_CS_HOLD_1;
                end
            end

            ST_CS_HOLD_1: begin
                if (timing_cnt >= CS_GUARD_CYCLES - 1) begin
                    timing_cnt   <= 32'd0;
                    spi_cs_n_reg <= 1'b1;

                    if (cmd_rw_reg)
                        state <= ST_READ_GAP;
                    else
                        state <= ST_WRITE_BUSY_GUARD;
                end
                else begin
                    timing_cnt <= timing_cnt + 32'd1;
                end
            end

            ST_WRITE_BUSY_GUARD: begin
                // WRITE 首帧结束后不能立即用 BUSY 高电平判断完成；先跨过 BUSY 可能尚未拉低的保护窗口。
                if (timing_cnt >= BUSY_GUARD_CYCLES - 1) begin
                    timing_cnt <= 32'd0;
                    timeout_cnt <= 32'd0;

                    if (busy_sync)
                        state <= ST_IDLE;
                    else
                        state <= ST_WRITE_BUSY_WAIT;
                end
                else begin
                    timing_cnt <= timing_cnt + 32'd1;
                end
            end

            ST_WRITE_BUSY_WAIT: begin
                if (busy_sync) begin
                    timeout_cnt <= 32'd0;
                    state       <= ST_IDLE;
                end
                else if (timeout_cnt >= BUSY_TIMEOUT_CYCLES - 1) begin
                    timeout_cnt <= 32'd0;
                    o_bus_fault <= 1'b1;
                    state       <= ST_FAULT;
                end
                else begin
                    timeout_cnt <= timeout_cnt + 32'd1;
                end
            end
            ST_READ_GAP: begin
                // READ 第一帧只提交地址；保持规定的 SYNC high 间隔后，再用 NOP 第二帧取回数据。
                if (timing_cnt >= READ_GAP_CYCLES - 1) begin
                    timing_cnt    <= 32'd0;
                    spi_tx_data   <= 24'h000000; // NOP
                    spi_cs_n_reg  <= 1'b0;
                    state         <= ST_CS_SETUP_2;
                end
                else begin
                    timing_cnt <= timing_cnt + 32'd1;
                end
            end

            ST_CS_SETUP_2: begin
                if (timing_cnt >= CS_GUARD_CYCLES - 1) begin
                    timing_cnt    <= 32'd0;
                    spi_req_valid <= 1'b1;
                    state         <= ST_SPI_REQ_2;
                end
                else begin
                    timing_cnt <= timing_cnt + 32'd1;
                end
            end

            ST_SPI_REQ_2: begin
                if (spi_req_valid && spi_req_ready) begin
                    spi_req_valid <= 1'b0;
                    state         <= ST_SPI_WAIT_2;
                end
            end

            ST_SPI_WAIT_2: begin
                if (spi_rx_valid) begin
                    // 第二帧结束才算 READ 真正完成，低 16 bit 作为寄存器读回值保存。
                    o_rsp_rd_data <= spi_rx_data[15:0];
                    timing_cnt    <= 32'd0;
                    state         <= ST_CS_HOLD_2;
                end
            end

            ST_CS_HOLD_2: begin
                if (timing_cnt >= CS_GUARD_CYCLES - 1) begin
                    timing_cnt   <= 32'd0;
                    spi_cs_n_reg <= 1'b1;
                    state        <= ST_READ_SDO_GUARD;
                end
                else begin
                    timing_cnt <= timing_cnt + 32'd1;
                end
            end

            ST_READ_SDO_GUARD: begin
                // 第二帧 SYNC 拉高后继续等待 SDO 释放，再发布 rsp_valid，避免读回结束过早。
                if (timing_cnt >= CS_GUARD_CYCLES - 1) begin
                    timing_cnt  <= 32'd0;
                    o_rsp_valid <= 1'b1;
                    state       <= ST_IDLE;
                end
                else begin
                    timing_cnt <= timing_cnt + 32'd1;
                end
            end

            ST_FAULT: begin
                spi_req_valid <= 1'b0;
                spi_cs_n_reg  <= 1'b1;
            end

            default: begin
                state         <= ST_IDLE;
                spi_req_valid <= 1'b0;
                spi_cs_n_reg  <= 1'b1;
            end
        endcase
    end
end

endmodule
