`timescale 1ns/1ps

/*
 * 模块说明
 *
 * 功能：
 * - 保存并按顺序执行 AD5560 初始化配置表。
 * - 通信侧可独立启动 Config RAM CRC-16/MODBUS 校验，校验结果只返回通信模块。
 * - System Controller 发出 cfg_start 后，按已校验的记录长度执行配置。
 *
 * 关键数据：
 * - Config RAM 固定 1024 x 32 bit。
 * - Record：[31:30] Reserved，[29:27] BUS_ID，[26:23] DEVICE_ID，
 *           [22:16] REG_ADDR，[15:0] REG_DATA。
 * - CRC 覆盖 RAM[0] ~ RAM[record_count-1]，每个 word 按
 *   [31:24] -> [23:16] -> [15:8] -> [7:0] 顺序送入 CRC。
 *
 * 关键约束：
 * - CRC 校验和配置执行是两个独立阶段；通信模块仅在 crc_ok 后向 System Controller 发启动请求。
 * - CRC 校验期间和配置执行期间禁止通信侧修改 Config RAM。
 * - crc_done 为单周期脉冲，crc_ok 为本轮 CRC 结果并保持到下一次 crc_start/reset。
 * - Config Table 仅产生 WRITE 命令。
 * - 最后一条命令提交后，必须等待 8 个 Driver 全部 ready 才产生 cfg_done。
 */

module config_manager (
    input  wire         i_clk,
    input  wire         i_rst_n,

    // Config RAM / CRC interface from communication module
    input  wire         i_cfg_ram_wr_en,
    input  wire [9:0]   i_cfg_ram_wr_addr,
    input  wire [31:0]  i_cfg_ram_wr_data,
    input  wire [10:0]  i_cfg_record_count,
    input  wire [15:0]  i_cfg_expected_crc,
    input  wire         i_cfg_crc_start,
    output reg          o_cfg_crc_done,
    output reg          o_cfg_crc_ok,

    // System control
    input  wire         i_cfg_start,
    input  wire         i_cfg_abort,
    output reg          o_cfg_busy,
    output reg          o_cfg_done,
    output reg          o_cfg_error,

    // 8 Driver ready summary
    input  wire [7:0]   i_cfg_bus_ready,

    // Common Driver command interface
    output reg          o_cmd_valid,
    input  wire         i_cmd_ready,
    output wire         o_cmd_rw,
    output reg  [2:0]   o_cmd_bus_id,
    output reg  [3:0]   o_cmd_device_id,
    output reg  [6:0]   o_cmd_reg_addr,
    output reg  [15:0]  o_cmd_wr_data
);

//-------------------------------------------------------------------
// Config RAM：A 口由通信侧写配置表，B 口由 CRC 检查和配置执行共用。
//-------------------------------------------------------------------
wire [31:0] cfg_ram_rd_data;
reg  [9:0]  cfg_ram_rd_addr;
reg  [10:0] record_count_reg;

wire        cfg_ram_wr_en;
wire        cfg_ram_rd_en;

assign o_cmd_rw      = 1'b0;
assign cfg_ram_wr_en = i_cfg_ram_wr_en && (state == ST_IDLE);
assign cfg_ram_rd_en = (state == ST_CRC_RAM_READ) ||
                       (state == ST_RAM_READ);

// CRC/执行期间 state 均非 IDLE，因此通信侧无法同时改写 RAM。
cfg_ram u_cfg_ram (
    .dia   (i_cfg_ram_wr_data),
    .addra (i_cfg_ram_wr_addr),
    .cea   (cfg_ram_wr_en),
    .clka  (i_clk),
    .dob   (cfg_ram_rd_data),
    .addrb (cfg_ram_rd_addr),
    .ceb   (cfg_ram_rd_en),
    .clkb  (i_clk)
);

//-------------------------------------------------------------------
// CRC-16/MODBUS：逐字节累计，每个 32-bit Record 按大端字节顺序参与计算。
//-------------------------------------------------------------------
reg  [15:0] expected_crc_reg;
reg  [31:0] crc_word_reg;
reg  [1:0]  crc_byte_index;
wire        crc_init;
wire        crc_data_valid;
reg  [7:0]  crc_data;
wire [15:0] crc_value;

assign crc_init       = (state == ST_CRC_INIT);
assign crc_data_valid = (state == ST_CRC_BYTE);

always @(*) begin
    case (crc_byte_index)
        2'd0: crc_data = crc_word_reg[31:24];
        2'd1: crc_data = crc_word_reg[23:16];
        2'd2: crc_data = crc_word_reg[15:8];
        default: crc_data = crc_word_reg[7:0];
    endcase
end

crc16_modbus u_crc16_modbus (
    .i_clk        (i_clk),
    .i_rst_n      (i_rst_n),
    .i_init       (crc_init),
    .i_data_valid (crc_data_valid),
    .i_data       (crc_data),
    .o_crc        (crc_value)
);

//-------------------------------------------------------------------
// FSM：CRC 校验和配置执行共用 RAM 读口，但由两个独立启动信号进入。
//-------------------------------------------------------------------
localparam [3:0] ST_IDLE           = 4'd0;
localparam [3:0] ST_CRC_INIT       = 4'd1;
localparam [3:0] ST_CRC_RAM_READ   = 4'd2;
localparam [3:0] ST_CRC_RAM_LOAD   = 4'd3;
localparam [3:0] ST_CRC_BYTE       = 4'd4;
localparam [3:0] ST_CRC_CHECK      = 4'd5;
localparam [3:0] ST_RAM_READ       = 4'd6;
localparam [3:0] ST_RAM_LOAD       = 4'd7;
localparam [3:0] ST_SEND           = 4'd8;
localparam [3:0] ST_WAIT_ALL_READY = 4'd9;

reg [3:0] state;

//-------------------------------------------------------------------
// 通信侧先 CRC_CHECK；crc_done/crc_ok 返回后，由通信模块决定是否再请求 System 执行配置。
//-------------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        state            <= ST_IDLE;
        cfg_ram_rd_addr  <= 10'd0;
        record_count_reg <= 11'd0;
        expected_crc_reg <= 16'd0;
        crc_word_reg     <= 32'd0;
        crc_byte_index   <= 2'd0;

        o_cfg_crc_done   <= 1'b0;
        o_cfg_crc_ok     <= 1'b0;
        o_cfg_busy       <= 1'b0;
        o_cfg_done       <= 1'b0;
        o_cfg_error      <= 1'b0;

        o_cmd_valid      <= 1'b0;
        o_cmd_bus_id     <= 3'd0;
        o_cmd_device_id  <= 4'd0;
        o_cmd_reg_addr   <= 7'd0;
        o_cmd_wr_data    <= 16'd0;
    end
    else begin
        // pulse 类输出默认清零；crc_ok 保持最近一次 CRC 结果。
        o_cfg_crc_done <= 1'b0;
        o_cfg_done     <= 1'b0;
        o_cfg_error    <= 1'b0;

        // abort 只作用于真正的配置执行；CRC 检查属于通信侧前置流程。
        if (i_cfg_abort && o_cfg_busy) begin
            state           <= ST_IDLE;
            cfg_ram_rd_addr <= 10'd0;
            o_cfg_busy      <= 1'b0;
            o_cfg_error     <= 1'b1;
            o_cmd_valid     <= 1'b0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    o_cmd_valid <= 1'b0;
                    o_cfg_busy  <= 1'b0;

                    // CRC 请求优先处理。长度非法也通过 crc_done/crc_ok 返回通信模块。
                    if (i_cfg_crc_start) begin
                        record_count_reg <= i_cfg_record_count;
                        expected_crc_reg <= i_cfg_expected_crc;
                        cfg_ram_rd_addr  <= 10'd0;
                        crc_byte_index   <= 2'd0;
                        o_cfg_crc_ok     <= 1'b0;

                        if (i_cfg_record_count > 11'd1024) begin
                            o_cfg_crc_done <= 1'b1;
                        end
                        else begin
                            state <= ST_CRC_INIT;
                        end
                    end
                    else if (i_cfg_start) begin
                        // cfg_start 只负责执行；record_count 使用最近一次 CRC 请求锁存的长度。
                        cfg_ram_rd_addr <= 10'd0;

                        if (record_count_reg == 11'd0) begin
                            o_cfg_done <= 1'b1;
                        end
                        else begin
                            o_cfg_busy <= 1'b1;
                            state      <= ST_RAM_READ;
                        end
                    end
                end

                // 独立 INIT 一拍，保证 crc16_modbus 从 16'hFFFF 开始本轮累计。
                ST_CRC_INIT: begin
                    cfg_ram_rd_addr <= 10'd0;
                    crc_byte_index  <= 2'd0;

                    if (record_count_reg == 11'd0)
                        state <= ST_CRC_CHECK;
                    else
                        state <= ST_CRC_RAM_READ;
                end

                // Config RAM 为同步读：REQ 给地址/使能，下一拍 LOAD 才能取得该 word。
                ST_CRC_RAM_READ: begin
                    state <= ST_CRC_RAM_LOAD;
                end

                ST_CRC_RAM_LOAD: begin
                    crc_word_reg   <= cfg_ram_rd_data;
                    crc_byte_index <= 2'd0;
                    state          <= ST_CRC_BYTE;
                end

                // 一个 RAM word 连续送 4 个 byte；第 4 byte 累计后推进地址。
                ST_CRC_BYTE: begin
                    if (crc_byte_index == 2'd3) begin
                        crc_byte_index <= 2'd0;

                        if ({1'b0, cfg_ram_rd_addr} == record_count_reg - 11'd1) begin
                            state <= ST_CRC_CHECK;
                        end
                        else begin
                            cfg_ram_rd_addr <= cfg_ram_rd_addr + 10'd1;
                            state           <= ST_CRC_RAM_READ;
                        end
                    end
                    else begin
                        crc_byte_index <= crc_byte_index + 2'd1;
                    end
                end

                // CRC 完成只通知通信模块；本状态不会自动启动配置，也不会通知 System Controller。
                ST_CRC_CHECK: begin
                    o_cfg_crc_ok   <= (crc_value == expected_crc_reg);
                    o_cfg_crc_done <= 1'b1;
                    state          <= ST_IDLE;
                end

                // System Controller 发 cfg_start 后才从 RAM[0] 开始真正执行配置。
                ST_RAM_READ: begin
                    state <= ST_RAM_LOAD;
                end

                // 将 32-bit Record 拆成 BUS/DEV/REG/DATA，并保持到目标 Driver 完成握手。
                ST_RAM_LOAD: begin
                    o_cmd_bus_id    <= cfg_ram_rd_data[29:27];
                    o_cmd_device_id <= cfg_ram_rd_data[26:23];
                    o_cmd_reg_addr  <= cfg_ram_rd_data[22:16];
                    o_cmd_wr_data   <= cfg_ram_rd_data[15:0];
                    o_cmd_valid     <= 1'b1;
                    state           <= ST_SEND;
                end

                ST_SEND: begin
                    // 未握手前 valid 与命令字段保持不变；握手成功后才推进 RAM 地址。
                    if (o_cmd_valid && i_cmd_ready) begin
                        o_cmd_valid <= 1'b0;

                        if ({1'b0, cfg_ram_rd_addr} == record_count_reg - 11'd1) begin
                            state <= ST_WAIT_ALL_READY;
                        end
                        else begin
                            cfg_ram_rd_addr <= cfg_ram_rd_addr + 10'd1;
                            state           <= ST_RAM_READ;
                        end
                    end
                end

                // 最后一条 WRITE 只表示已提交给 Driver；8 路 ready 全部恢复后才报告 cfg_done。
                ST_WAIT_ALL_READY: begin
                    if (i_cfg_bus_ready == 8'hFF) begin
                        o_cfg_busy <= 1'b0;
                        o_cfg_done <= 1'b1;
                        state      <= ST_IDLE;
                    end
                end

                default: begin
                    state        <= ST_IDLE;
                    o_cfg_busy   <= 1'b0;
                    o_cmd_valid  <= 1'b0;
                end
            endcase
        end
    end
end

endmodule
