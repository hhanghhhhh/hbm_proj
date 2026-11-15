`timescale 1ns/1ps

/*
 * 通用配置指令管理器：先按阶段分发，再由 8 个 BUS 独立执行。
 * Record: OP[31:30]，BUS[29:27]，DEV[26:23]，ADDR[22:16]，DATA[15:0]。
 * OP=00 WRITE，01 DELAY(ms)；DELAY 0 为全局 SPI 屏障，其余 OP 报错。
 * CRC 与执行独立，长度沿用最近一次 CRC 请求；启动授权仍由上层负责。
 * SYS_CLK_FREQ 必须为不小于 1000 的 1000 整数倍。所有接口均在 i_clk 域。
 * 故障沿用上层 i_cfg_abort，已提交事务由既有 Driver/System 排空。
 */
module config_manager_parallel #(
    parameter SYS_CLK_FREQ = 100_000_000
) (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_cfg_ram_wr_en,
    input  wire [9:0]  i_cfg_ram_wr_addr,
    input  wire [31:0] i_cfg_ram_wr_data,
    input  wire [10:0] i_cfg_record_count,
    input  wire [15:0] i_cfg_expected_crc,
    input  wire        i_cfg_crc_start,
    output reg         o_cfg_crc_done,
    output reg         o_cfg_crc_ok,
    input  wire        i_cfg_start,
    input  wire        i_cfg_abort,
    output reg         o_cfg_busy,
    output reg         o_cfg_done,
    output reg         o_cfg_error,
    input  wire [7:0]  i_cfg_bus_ready,
    output wire        o_cmd_valid,
    input  wire        i_cmd_ready,
    output wire        o_cmd_rw,
    output reg  [2:0]  o_cmd_bus_id,
    output reg  [3:0]  o_cmd_device_id,
    output reg  [6:0]  o_cmd_reg_addr,
    output reg  [15:0] o_cmd_wr_data
);

localparam [3:0] ST_IDLE         = 4'd0;
localparam [3:0] ST_CRC_INIT     = 4'd1;
localparam [3:0] ST_CRC_READ     = 4'd2;
localparam [3:0] ST_CRC_LOAD     = 4'd3;
localparam [3:0] ST_CRC_BYTE     = 4'd4;
localparam [3:0] ST_CRC_CHECK    = 4'd5;
localparam [3:0] ST_STAGE_CLEAR  = 4'd6;
localparam [3:0] ST_RAM_READ     = 4'd7;
localparam [3:0] ST_RAM_LOAD     = 4'd8;
localparam [3:0] ST_STAGE_START  = 4'd9;
localparam [3:0] ST_RUN          = 4'd10;
localparam [3:0] ST_DRAIN        = 4'd11;
localparam [3:0] ST_DELAY        = 4'd12;
localparam integer CYCLES_PER_MS = SYS_CLK_FREQ / 1000;

reg [3:0] state;
reg [9:0] cfg_ram_rd_addr;
reg [10:0] record_count_reg;
// 原表的全局读取/分发位置；可取 1024，独立于各 BUS 的执行进度。
reg [10:0] record_index;
wire [31:0] cfg_ram_rd_data;
wire cfg_ram_rd_en;
wire cfg_ram_wr_en;
reg [15:0] expected_crc_reg;
reg [31:0] crc_word_reg;
reg [1:0] crc_byte_index;
reg [7:0] crc_data;
wire [15:0] crc_value;

assign cfg_ram_wr_en = i_cfg_ram_wr_en && (state == ST_IDLE) &&
                       !i_cfg_crc_start && !i_cfg_start;
assign cfg_ram_rd_en = (state == ST_CRC_READ) || (state == ST_RAM_READ);
assign o_cmd_rw = 1'b0;

// 沿用现有 IP 接口及同步读时序，不改变通信侧 32 bit 大端拼接约定。
cfg_ram u_cfg_ram (
    .dia(i_cfg_ram_wr_data), .addra(i_cfg_ram_wr_addr),
    .cea(cfg_ram_wr_en), .clka(i_clk),
    .dob(cfg_ram_rd_data), .addrb(cfg_ram_rd_addr),
    .ceb(cfg_ram_rd_en), .clkb(i_clk)
);

always @(*) begin
    crc_data = crc_word_reg[7:0];
    case (crc_byte_index)
        2'd0: crc_data = crc_word_reg[31:24];
        2'd1: crc_data = crc_word_reg[23:16];
        2'd2: crc_data = crc_word_reg[15:8];
        default: crc_data = crc_word_reg[7:0];
    endcase
end

crc16_modbus u_crc16_modbus (
    .i_clk(i_clk), .i_rst_n(i_rst_n),
    .i_init(state == ST_CRC_INIT),
    .i_data_valid(state == ST_CRC_BYTE),
    .i_data(crc_data), .o_crc(crc_value)
);

wire [7:0] bus_pending; // 8 个 Executor 是否还有未提交的命令（也就是本次 start 是否结束，整个阶段完成标志）
wire [7:0] bus_valid; // 8 个 Executor 哪些已经准备好队首命令
wire [215:0] bus_record;
wire queue_clear;
wire invalid_record;
wire command_take;
reg cmd_valid;
reg [2:0] rr_next;  // 下一轮从哪个 BUS 开始搜索
reg pick_valid; // 是否找到了可以执行的 BUS
reg [2:0] pick_bus; // 本次选中的 BUS
integer scan_index;
integer scan_bus;
reg phase_last;
reg [15:0] delay_remaining;
reg [31:0] ms_cycle_count;

// OP = 10/11 非法，00/01 合法
assign invalid_record = (state == ST_RAM_LOAD) && cfg_ram_rd_data[31];
assign queue_clear = (state == ST_STAGE_CLEAR) ||
                     (i_cfg_abort && o_cfg_busy) || invalid_record;
// Abort 是对 valid 保持规则的取消例外；到来当拍即禁止新的握手。
assign o_cmd_valid = cmd_valid && !i_cfg_abort && i_rst_n;
assign command_take = o_cmd_valid && i_cmd_ready;

genvar bus_i;
generate
    for (bus_i = 0; bus_i < 8; bus_i = bus_i + 1) begin : gen_bus
        config_bus_executor u_executor (
            .i_clk(i_clk), .i_rst_n(i_rst_n), .i_clear(queue_clear),
            .i_load((state == ST_RAM_LOAD) && !i_cfg_abort &&
                    (cfg_ram_rd_data[31:30] == 2'b00) &&
                    (cfg_ram_rd_data[29:27] == bus_i)),
            .i_record(cfg_ram_rd_data[26:0]),
            .i_start(state == ST_STAGE_START),
            .i_take(command_take && (o_cmd_bus_id == bus_i)), // 命令真正提交外部 driver 后，才推进对应 Executor
            .o_pending(bus_pending[bus_i]), .o_valid(bus_valid[bus_i]),
            .o_record(bus_record[bus_i*27 +: 27])
        );
    end
endgenerate

// 从上次成功握手的下一 BUS 开始扫描；只挑选有队首且 Driver ready 的 BUS。
// 一旦进入公共输出寄存器，即锁定选择，反压时不能换发其他命令。
always @(*) begin
    pick_valid = 1'b0;
    pick_bus = 3'd0;
    scan_bus = 3'd0;
    for (scan_index = 0; scan_index < 8; scan_index = scan_index + 1) begin
        // 3-bit 相加，自动实现 MOD 8
        scan_bus = rr_next + scan_index[2:0];
        // 仲裁器选择当前可用 BUS
        if (!pick_valid && bus_valid[scan_bus] && i_cfg_bus_ready[scan_bus]) begin
            pick_valid = 1'b1;
            pick_bus = scan_bus;
        end
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        state <= ST_IDLE;
        cfg_ram_rd_addr <= 10'd0;
        record_count_reg <= 11'd0;
        record_index <= 11'd0;
        expected_crc_reg <= 16'd0;
        crc_word_reg <= 32'd0;
        crc_byte_index <= 2'd0;
        o_cfg_crc_done <= 1'b0;
        o_cfg_crc_ok <= 1'b0;
        o_cfg_busy <= 1'b0;
        o_cfg_done <= 1'b0;
        o_cfg_error <= 1'b0;
        cmd_valid <= 1'b0;
        o_cmd_bus_id <= 3'd0;
        o_cmd_device_id <= 4'd0;
        o_cmd_reg_addr <= 7'd0;
        o_cmd_wr_data <= 16'd0;
        rr_next <= 3'd0;
        phase_last <= 1'b0;
        delay_remaining <= 16'd0;
        ms_cycle_count <= 32'd0;
    end
    else begin
        o_cfg_crc_done <= 1'b0;
        o_cfg_done <= 1'b0;
        o_cfg_error <= 1'b0;
        if (i_cfg_abort && o_cfg_busy) begin
            // 保留 record_index 供定位，队列同沿清空；不会自动续跑。
            state <= ST_IDLE;
            o_cfg_busy <= 1'b0;
            o_cfg_error <= 1'b1;
            cmd_valid <= 1'b0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    cmd_valid <= 1'b0;
                    o_cfg_busy <= 1'b0;
                    // 保持 CRC 优先；CRC 结果只回通信模块，不自动触发执行。
                    if (i_cfg_crc_start) begin
                        record_count_reg <= i_cfg_record_count;
                        expected_crc_reg <= i_cfg_expected_crc;
                        cfg_ram_rd_addr <= 10'd0;
                        crc_byte_index <= 2'd0;
                        o_cfg_crc_ok <= 1'b0;
                        if (i_cfg_record_count > 11'd1024)
                            o_cfg_crc_done <= 1'b1;
                        else
                            state <= ST_CRC_INIT;
                    end
                    else if (i_cfg_start) begin
                        cfg_ram_rd_addr <= 10'd0;
                        record_index <= 11'd0;
                        rr_next <= 3'd0;
                        phase_last <= 1'b0;
                        delay_remaining <= 16'd0;
                        if (record_count_reg > 11'd1024)
                            o_cfg_error <= 1'b1;
                        else begin
                            o_cfg_busy <= 1'b1;
                            state <= ST_STAGE_CLEAR;
                        end
                    end
                end
                ST_CRC_INIT: begin
                    if (record_count_reg == 11'd0)
                        state <= ST_CRC_CHECK;
                    else
                        state <= ST_CRC_READ;
                end
                ST_CRC_READ: state <= ST_CRC_LOAD;
                ST_CRC_LOAD: begin
                    crc_word_reg <= cfg_ram_rd_data;
                    crc_byte_index <= 2'd0;
                    state <= ST_CRC_BYTE;
                end
                ST_CRC_BYTE: begin
                    if (crc_byte_index == 2'd3) begin
                        crc_byte_index <= 2'd0;
                        if ({1'b0, cfg_ram_rd_addr} == record_count_reg - 11'd1)
                            state <= ST_CRC_CHECK;
                        else begin
                            cfg_ram_rd_addr <= cfg_ram_rd_addr + 10'd1;
                            state <= ST_CRC_READ;
                        end
                    end
                    else
                        crc_byte_index <= crc_byte_index + 2'd1;
                end
                ST_CRC_CHECK: begin
                    o_cfg_crc_ok <= (crc_value == expected_crc_reg);
                    o_cfg_crc_done <= 1'b1;
                    state <= ST_IDLE;
                end
                ST_STAGE_CLEAR: begin
                    delay_remaining <= 16'd0;
                    if (record_index == record_count_reg) begin
                        // 空表同样经过 SPI 排空屏障，不提前报告完成。
                        phase_last <= 1'b1;
                        state <= ST_DRAIN;
                    end
                    else
                        state <= ST_RAM_READ;
                end
                ST_RAM_READ: state <= ST_RAM_LOAD;
                ST_RAM_LOAD: begin
                    if (invalid_record) begin
                        o_cfg_error <= 1'b1;
                        o_cfg_busy <= 1'b0;
                        cmd_valid <= 1'b0;
                        state <= ST_IDLE;
                    end
                    else begin
                        record_index <= record_index + 11'd1;
                        if (record_index + 11'd1 < record_count_reg)
                            cfg_ram_rd_addr <= cfg_ram_rd_addr + 10'd1;
                        if (cfg_ram_rd_data[31:30] == 2'b01) begin
                            delay_remaining <= cfg_ram_rd_data[15:0];
                            phase_last <= (record_index + 11'd1 == record_count_reg);
                            state <= ST_STAGE_START;
                        end
                        else if (record_index + 11'd1 == record_count_reg) begin
                            phase_last <= 1'b1;
                            state <= ST_STAGE_START;
                        end
                        else
                            state <= ST_RAM_READ;
                    end
                end
                ST_STAGE_START: state <= ST_RUN;
                ST_RUN: begin
                    if (cmd_valid) begin
                        if (command_take) begin
                            cmd_valid <= 1'b0;
                            rr_next <= o_cmd_bus_id + 3'd1;
                        end
                    end
                    else if (pick_valid) begin
                        cmd_valid <= 1'b1;
                        o_cmd_bus_id <= pick_bus;
                        {o_cmd_device_id, o_cmd_reg_addr, o_cmd_wr_data} <=
                            bus_record[pick_bus*27 +: 27];
                    end
                    else if (bus_pending == 8'd0)
                        state <= ST_DRAIN;
                end
                // 与最后一次提交至少隔开状态转换，避免采到握手前旧的全 ready。
                ST_DRAIN: begin
                    if (i_cfg_bus_ready == 8'hFF) begin
                        ms_cycle_count <= 32'd0;
                        if (delay_remaining != 16'd0)
                            state <= ST_DELAY;
                        else if (phase_last) begin
                            o_cfg_busy <= 1'b0;
                            o_cfg_done <= 1'b1;
                            state <= ST_IDLE;
                        end
                        else
                            state <= ST_STAGE_CLEAR;
                    end
                end
                // 仅排空后开始计时；每个毫秒完整经过 CYCLES_PER_MS 个时钟。
                ST_DELAY: begin
                    if (ms_cycle_count == CYCLES_PER_MS - 1) begin
                        ms_cycle_count <= 32'd0;
                        delay_remaining <= delay_remaining - 16'd1;
                        if (delay_remaining == 16'd1) begin
                            if (phase_last) begin
                                o_cfg_busy <= 1'b0;
                                o_cfg_done <= 1'b1;
                                state <= ST_IDLE;
                            end
                            else
                                state <= ST_STAGE_CLEAR;
                        end
                    end
                    else
                        ms_cycle_count <= ms_cycle_count + 32'd1;
                end
                default: begin
                    state <= ST_IDLE;
                    o_cfg_busy <= 1'b0;
                    cmd_valid <= 1'b0;
                    o_cfg_error <= 1'b1;
                end
            endcase
        end
    end
end

endmodule
