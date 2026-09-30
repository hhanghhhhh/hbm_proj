`timescale 1ns/1ps

/*
 * 模块说明
 *
 * 功能：
 * - 执行 AD5560 POWER_ON / POWER_OFF Ramp 参数装载和 Sequence。
 * - 通信侧可独立启动 Power Sequence RAM CRC-16/MODBUS 校验，结果只返回通信模块。
 * - 根据 8 路 Driver ready 独立调度，不允许某一路 BUS 阻塞其他 BUS。
 *
 * 关键数据：
 * - Sequence RAM：2048 x 16 bit；Header 固定 20 word。
 * - Header 直接保存每个 BUS 的 Parameter 起始地址和 Record 数量。
 * - Parameter Record：DEVICE_ID + UP/DOWN Ramp 参数，共 7 word。
 * - Sequence Step：8 word TRIGGER_MASK + 1 word Delay_ms。
 *
 * 关键约束：
 * - i_seq_mode：0=POWER_ON，1=POWER_OFF。
 * - CRC 覆盖 RAM[0] ~ RAM[word_count-1]，每个 16-bit word 按 [15:8] -> [7:0] 顺序累计。
 * - CRC 校验和 Sequence 执行为两个独立阶段；CRC 完成后不会自动启动执行。
 * - FPGA 不再根据 EN_MASK 推导执行信息，只按 RAM 执行。
 * - 参数全部提交后等待 8 个 Driver 全 ready，再进入 Sequence。
 * - busy 期间重复 start 忽略；abort 优先于正常完成。
 */

module power_sequence_engine #(
    parameter SYS_CLK_FREQ = 100_000_000
)(
    input  wire         i_clk,
    input  wire         i_rst_n,

    // Power Sequence RAM / CRC interface from communication module
    input  wire         i_seq_ram_wr_en,
    input  wire [10:0]  i_seq_ram_wr_addr,
    input  wire [15:0]  i_seq_ram_wr_data,
    input  wire [11:0]  i_seq_word_count,
    input  wire [15:0]  i_seq_expected_crc,
    input  wire         i_seq_crc_start,
    output reg          o_seq_crc_done,
    output reg          o_seq_crc_ok,

    // System control
    input  wire         i_seq_start,
    input  wire         i_seq_mode,
    input  wire         i_seq_abort,
    output reg          o_seq_busy,
    output reg          o_seq_done,

    // 8 Driver ready summary
    input  wire [7:0]   i_seq_bus_ready,

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
// Constants
//-------------------------------------------------------------------
localparam MODE_POWER_ON  = 1'b0;
localparam MODE_POWER_OFF = 1'b1;

localparam [6:0] REG_RAMP_END  = 7'h3E;
localparam [6:0] REG_RAMP_STEP = 7'h3F;
localparam [6:0] REG_RCLK_DIV  = 7'h40;
localparam [6:0] REG_RAMP_EN   = 7'h41;

localparam integer CLK_PER_MS = SYS_CLK_FREQ / 1000;

assign o_cmd_rw = 1'b0;
//-------------------------------------------------------------------
// Power Sequence RAM
//-------------------------------------------------------------------
wire [15:0] seq_ram_rd_data;
reg  [10:0] seq_ram_rd_addr;
reg         seq_ram_rd_en;
wire        seq_ram_wr_en;

assign seq_ram_wr_en = i_seq_ram_wr_en && (state == ST_IDLE);

// CRC/执行期间 state 均非 IDLE，因此通信侧无法同时改写 RAM。
seq_ram u_seq_ram (
    .dia   (i_seq_ram_wr_data),
    .addra (i_seq_ram_wr_addr),
    .cea   (seq_ram_wr_en),
    .clka  (i_clk),
    .dob   (seq_ram_rd_data),
    .addrb (seq_ram_rd_addr),
    .ceb   (seq_ram_rd_en),
    .clkb  (i_clk)
);

//-------------------------------------------------------------------
// CRC-16/MODBUS：逐字节累计，每个 16-bit word 按高字节 -> 低字节参与计算。
//-------------------------------------------------------------------
reg  [11:0] crc_word_count_reg;
reg  [15:0] expected_crc_reg;
reg  [15:0] crc_word_reg;
reg         crc_byte_index;
wire        crc_init;
wire        crc_data_valid;
wire [7:0]  crc_data;
wire [15:0] crc_value;

assign crc_init       = (state == ST_CRC_INIT);
assign crc_data_valid = (state == ST_CRC_BYTE);
assign crc_data       = crc_byte_index ? crc_word_reg[7:0] : crc_word_reg[15:8];

crc16_modbus u_crc16_modbus (
    .i_clk        (i_clk),
    .i_rst_n      (i_rst_n),
    .i_init       (crc_init),
    .i_data_valid (crc_data_valid),
    .i_data       (crc_data),
    .o_crc        (crc_value)
);

//-------------------------------------------------------------------
// FSM
//-------------------------------------------------------------------
localparam [4:0] ST_IDLE           = 5'd0;
localparam [4:0] ST_HEADER_REQ     = 5'd1;
localparam [4:0] ST_HEADER_LOAD    = 5'd2;
localparam [4:0] ST_HEADER_DECIDE  = 5'd3;
localparam [4:0] ST_PARAM_SCHED    = 5'd4;
localparam [4:0] ST_PARAM_REQ      = 5'd5;
localparam [4:0] ST_PARAM_LOAD     = 5'd6;
localparam [4:0] ST_PARAM_SEND     = 5'd7;
localparam [4:0] ST_PARAM_BARRIER  = 5'd8;
localparam [4:0] ST_STEP_REQ       = 5'd9;
localparam [4:0] ST_STEP_LOAD      = 5'd10;
localparam [4:0] ST_SEQ_SCHED      = 5'd11;
localparam [4:0] ST_SEQ_SEND       = 5'd12;
localparam [4:0] ST_DELAY          = 5'd13;
localparam [4:0] ST_STEP_ADVANCE   = 5'd14;
localparam [4:0] ST_CRC_INIT       = 5'd15;
localparam [4:0] ST_CRC_RAM_READ   = 5'd16;
localparam [4:0] ST_CRC_RAM_LOAD   = 5'd17;
localparam [4:0] ST_CRC_BYTE       = 5'd18;
localparam [4:0] ST_CRC_CHECK      = 5'd19;

reg [4:0] state;
reg [10:0] crc_word_index;
//-------------------------------------------------------------------
// Header / runtime context
//-------------------------------------------------------------------
reg         seq_mode_reg;
reg [10:0]  up_sequence_start;
reg [15:0]  up_step_count;
reg [10:0]  down_sequence_start;
reg [15:0]  down_step_count;
reg [10:0]  param_start_cfg [0:7];
reg [15:0]  param_count_cfg [0:7];
reg [4:0]   header_word_index;

reg [10:0]  step_base_addr;
reg [15:0]  step_count_reg;
reg [15:0]  step_index;
reg [3:0]   step_word_index;
reg [127:0] pending_mask;
reg [15:0]  delay_ms_reg;
reg [15:0]  delay_ms_cnt;
reg [31:0]  delay_clk_cnt;

//-------------------------------------------------------------------
// 每条 BUS 独立保存 Parameter 读取进度，调度器可在不同 BUS 之间切换而不丢失上下文。
//-------------------------------------------------------------------
reg [10:0] param_ptr       [0:7];
reg [15:0] param_left      [0:7];
// phase=0 读取 DEVICE_ID；phase=1/2/3 依次处理 Ramp End / Ramp Step / RCLK Divider。
reg [1:0]  param_phase     [0:7];
reg [3:0]  param_device_id [0:7];

reg [2:0] selected_bus;

integer reset_i;
integer sched_i;
integer seq_i;

//-------------------------------------------------------------------
// Parameter Scheduler：固定 BUS0→BUS7 优先级选择“仍有 Record 且 Driver ready”的 BUS；busy BUS 直接跳过。
//-------------------------------------------------------------------
reg       param_select_valid;
reg [2:0] param_select_bus;
reg       param_all_done;

// 这里只产生当前组合候选；FSM 在进入 ST_PARAM_REQ 前锁存 selected_bus，后续多拍 RAM 访问不再跟随组合结果变化。
always @(*) begin
    param_select_valid = 1'b0;
    param_select_bus   = 3'd0;
    param_all_done     = 1'b1;

    for (sched_i = 0; sched_i < 8; sched_i = sched_i + 1) begin
        if (param_left[sched_i] != 16'd0)
            param_all_done = 1'b0;

        if (!param_select_valid &&
            (param_left[sched_i] != 16'd0) &&
            i_seq_bus_ready[sched_i]) begin
            param_select_valid = 1'b1;
            param_select_bus   = sched_i[2:0];
        end
    end
end
reg       seq_select_valid;
reg [2:0] seq_select_bus;
reg [3:0] seq_select_device;

always @(*) begin
    seq_select_valid  = 1'b0;
    seq_select_bus    = 3'd0;
    seq_select_device = 4'd0;

    // Sequence Scheduler：从低 Channel 向高 Channel 找 pending bit；目标 BUS busy 时跳过，其他 BUS 可继续触发。
    for (seq_i = 0; seq_i < 128; seq_i = seq_i + 1) begin
        if (!seq_select_valid && pending_mask[seq_i] &&
            i_seq_bus_ready[seq_i >> 4]) begin
            seq_select_valid  = 1'b1;
            seq_select_bus    = seq_i >> 4;
            seq_select_device = seq_i[3:0];
        end
    end
end

//-------------------------------------------------------------------
// RAM 读地址由当前阶段统一生成：Header 顺序读；Parameter 根据 phase/mode 选字段；Step 每次读 8 个 mask word + delay。
//-------------------------------------------------------------------
always @(*) begin
    seq_ram_rd_en   = 1'b0;
    seq_ram_rd_addr = 11'd0;

    case (state)
        ST_CRC_RAM_READ: begin
            seq_ram_rd_en   = 1'b1;
            seq_ram_rd_addr = crc_word_index;
        end

        ST_HEADER_REQ: begin
            seq_ram_rd_en   = 1'b1;
            seq_ram_rd_addr = header_word_index;
        end

        ST_PARAM_REQ: begin
            seq_ram_rd_en = 1'b1;

            if (param_phase[selected_bus] == 2'd0)
                seq_ram_rd_addr = param_ptr[selected_bus];
            else if (seq_mode_reg == MODE_POWER_ON)
                seq_ram_rd_addr = param_ptr[selected_bus] + param_phase[selected_bus];
            else
                seq_ram_rd_addr = param_ptr[selected_bus] + 11'd3 + param_phase[selected_bus];
        end

        ST_STEP_REQ: begin
            seq_ram_rd_en   = 1'b1;
            seq_ram_rd_addr = step_base_addr + step_word_index;
        end

        default: ;
    endcase
end
//-------------------------------------------------------------------
// 主流程：读 Header -> 并行调度各 BUS 参数 -> 等全部 Driver 空闲 -> 执行 Step Trigger/Delay -> 下一 Step。
//-------------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        state                <= ST_IDLE;
        crc_word_count_reg   <= 12'd0;
        expected_crc_reg     <= 16'd0;
        crc_word_reg         <= 16'd0;
        crc_word_index       <= 11'd0;
        crc_byte_index       <= 1'b0;
        seq_mode_reg         <= MODE_POWER_ON;
        up_sequence_start    <= 11'd0;
        up_step_count        <= 16'd0;
        down_sequence_start  <= 11'd0;
        down_step_count      <= 16'd0;
        header_word_index    <= 5'd0;
        step_base_addr       <= 11'd0;
        step_count_reg       <= 16'd0;
        step_index           <= 16'd0;
        step_word_index      <= 4'd0;
        pending_mask         <= 128'd0;
        delay_ms_reg         <= 16'd0;
        delay_ms_cnt         <= 16'd0;
        delay_clk_cnt        <= 32'd0;
        selected_bus         <= 3'd0;

        o_seq_crc_done       <= 1'b0;
        o_seq_crc_ok         <= 1'b0;
        o_seq_busy           <= 1'b0;
        o_seq_done           <= 1'b0;
        o_cmd_valid          <= 1'b0;
        o_cmd_bus_id         <= 3'd0;
        o_cmd_device_id      <= 4'd0;
        o_cmd_reg_addr       <= 7'd0;
        o_cmd_wr_data        <= 16'd0;

        for (reset_i = 0; reset_i < 8; reset_i = reset_i + 1) begin
            param_start_cfg[reset_i] <= 11'd0;
            param_count_cfg[reset_i] <= 16'd0;
            param_ptr[reset_i]       <= 11'd0;
            param_left[reset_i]      <= 16'd0;
            param_phase[reset_i]     <= 2'd0;
            param_device_id[reset_i] <= 4'd0;
        end
    end
    else begin
        o_seq_crc_done <= 1'b0;
        o_seq_done     <= 1'b0;

        // abort 只作用于真正的 Sequence 执行；CRC 检查属于通信侧前置流程。
        if (i_seq_abort && o_seq_busy) begin
            state              <= ST_IDLE;
            o_seq_busy         <= 1'b0;
            o_cmd_valid        <= 1'b0;
            pending_mask       <= 128'd0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    o_seq_busy  <= 1'b0;
                    o_cmd_valid <= 1'b0;

                    // CRC 请求优先处理。长度非法通过 crc_done/crc_ok 返回通信模块。
                    if (i_seq_crc_start) begin
                        crc_word_count_reg <= i_seq_word_count;
                        expected_crc_reg   <= i_seq_expected_crc;
                        crc_word_index     <= 11'd0;
                        crc_byte_index     <= 1'b0;
                        o_seq_crc_ok       <= 1'b0;

                        if (i_seq_word_count > 12'd2048) begin
                            o_seq_crc_done <= 1'b1;
                        end
                        else begin
                            state <= ST_CRC_INIT;
                        end
                    end
                    else if (i_seq_start) begin
                        seq_mode_reg      <= i_seq_mode;
                        header_word_index <= 5'd0;
                        o_seq_busy        <= 1'b1;
                        state             <= ST_HEADER_REQ;
                    end
                end

                // CRC 从初值 16'hFFFF 开始；空 RAM Image 直接进入比较状态。
                ST_CRC_INIT: begin
                    crc_word_index <= 11'd0;
                    crc_byte_index <= 1'b0;

                    if (crc_word_count_reg == 12'd0)
                        state <= ST_CRC_CHECK;
                    else
                        state <= ST_CRC_RAM_READ;
                end

                // Sequence RAM 为同步读：REQ 给地址/使能，下一拍 LOAD 才取得该 word。
                ST_CRC_RAM_READ: begin
                    state <= ST_CRC_RAM_LOAD;
                end

                ST_CRC_RAM_LOAD: begin
                    crc_word_reg   <= seq_ram_rd_data;
                    crc_byte_index <= 1'b0;
                    state          <= ST_CRC_BYTE;
                end

                // 每个 16-bit word 依次累计高/低两个字节；低字节完成后再推进 RAM 地址。
                ST_CRC_BYTE: begin
                    if (crc_byte_index) begin
                        crc_byte_index <= 1'b0;

                        if ({1'b0, crc_word_index} == crc_word_count_reg - 12'd1) begin
                            state <= ST_CRC_CHECK;
                        end
                        else begin
                            crc_word_index <= crc_word_index + 11'd1;
                            state          <= ST_CRC_RAM_READ;
                        end
                    end
                    else begin
                        crc_byte_index <= 1'b1;
                    end
                end

                // CRC 完成只通知通信模块；不会自动启动 Power Sequence，也不会通知 System Controller。
                ST_CRC_CHECK: begin
                    o_seq_crc_ok   <= (crc_value == expected_crc_reg);
                    o_seq_crc_done <= 1'b1;
                    state          <= ST_IDLE;
                end

                // Header 使用同步 RAM：REQ 给地址/使能，下一拍 LOAD 才读取 dob。
                ST_HEADER_REQ: begin
                    state <= ST_HEADER_LOAD;
                end

                ST_HEADER_LOAD: begin
                    if (header_word_index == 5'd0)
                        up_sequence_start <= seq_ram_rd_data[10:0];
                    else if (header_word_index == 5'd1)
                        up_step_count <= seq_ram_rd_data;
                    else if (header_word_index == 5'd2)
                        down_sequence_start <= seq_ram_rd_data[10:0];
                    else if (header_word_index == 5'd3)
                        down_step_count <= seq_ram_rd_data;
                    else if (header_word_index <= 5'd11)
                        param_start_cfg[header_word_index - 5'd4] <= seq_ram_rd_data[10:0];
                    else
                        param_count_cfg[header_word_index - 5'd12] <= seq_ram_rd_data;

                    if (header_word_index == 5'd19) begin
                        state <= ST_HEADER_DECIDE;
                    end
                    else begin
                        header_word_index <= header_word_index + 5'd1;
                        state             <= ST_HEADER_REQ;
                    end
                end
                // Header 全部锁存后确定本轮 ON/OFF 的 Step 区域，并初始化 8 条 BUS 的 Parameter 指针。
                ST_HEADER_DECIDE: begin
                    step_index         <= 16'd0;
                    step_word_index    <= 4'd0;
                    pending_mask       <= 128'd0;

                    for (reset_i = 0; reset_i < 8; reset_i = reset_i + 1) begin
                        param_ptr[reset_i]   <= param_start_cfg[reset_i];
                        param_left[reset_i]  <= param_count_cfg[reset_i];
                        param_phase[reset_i] <= 2'd0;
                    end

                    if (seq_mode_reg == MODE_POWER_ON) begin
                        step_base_addr <= up_sequence_start;
                        step_count_reg <= up_step_count;

                        if (up_step_count == 16'd0) begin
                            o_seq_busy <= 1'b0;
                            o_seq_done <= 1'b1;
                            state      <= ST_IDLE;
                        end
                        else begin
                            state <= ST_PARAM_SCHED;
                        end
                    end
                    else begin
                        step_base_addr <= down_sequence_start;
                        step_count_reg <= down_step_count;

                        if (down_step_count == 16'd0) begin
                            o_seq_busy <= 1'b0;
                            o_seq_done <= 1'b1;
                            state      <= ST_IDLE;
                        end
                        else begin
                            state <= ST_PARAM_SCHED;
                        end
                    end
                end

                // 每提交一笔 Parameter 命令都重新调度，使刚变 busy 的 BUS 能让出通路给其他 ready BUS。
                ST_PARAM_SCHED: begin
                    o_cmd_valid <= 1'b0;

                    if (param_all_done) begin
                        state <= ST_PARAM_BARRIER;
                    end
                    else if (param_select_valid) begin
                        selected_bus <= param_select_bus;
                        state        <= ST_PARAM_REQ;
                    end
                end

                ST_PARAM_REQ: begin
                    state <= ST_PARAM_LOAD;
                end

                ST_PARAM_LOAD: begin
                    // phase0 只读取并锁存 DEVICE_ID，不占用 Driver，因此直接继续读取同一 Record 的参数字段。
                    if (param_phase[selected_bus] == 2'd0) begin
                        param_device_id[selected_bus] <= seq_ram_rd_data[3:0];
                        param_phase[selected_bus]     <= 2'd1;
                        state                         <= ST_PARAM_REQ;
                    end
                    else begin
                        // phase1~3 形成 Driver 写命令；握手后回 Scheduler，重新判断下一条可执行 BUS。
                        o_cmd_bus_id    <= selected_bus;
                        o_cmd_device_id <= param_device_id[selected_bus];
                        o_cmd_wr_data   <= seq_ram_rd_data;

                        case (param_phase[selected_bus])
                            2'd1: o_cmd_reg_addr <= REG_RAMP_END;
                            2'd2: o_cmd_reg_addr <= REG_RAMP_STEP;
                            2'd3: o_cmd_reg_addr <= REG_RCLK_DIV;
                            default: o_cmd_reg_addr <= REG_RAMP_END;
                        endcase

                        o_cmd_valid <= 1'b1;
                        state       <= ST_PARAM_SEND;
                    end
                end

                // valid/ready 成功后才推进 phase；Divider 提交后该 Record 才算完成，ptr +7、left -1。
                ST_PARAM_SEND: begin
                    if (o_cmd_valid && i_cmd_ready) begin
                        o_cmd_valid <= 1'b0;

                        if (param_phase[selected_bus] == 2'd3) begin
                            param_phase[selected_bus] <= 2'd0;
                            param_ptr[selected_bus]   <= param_ptr[selected_bus] + 11'd7;
                            param_left[selected_bus]  <= param_left[selected_bus] - 16'd1;
                        end
                        else begin
                            param_phase[selected_bus] <= param_phase[selected_bus] + 2'd1;
                        end

                        state <= ST_PARAM_SCHED;
                    end
                end
                // Parameter 只是“提交给 Driver”即完成；进入 Sequence 前必须等 8 个 Driver 都重新 ready，确保参数已真正执行完。
                ST_PARAM_BARRIER: begin
                    if (i_seq_bus_ready == 8'hFF) begin
                        step_word_index <= 4'd0;
                        pending_mask    <= 128'd0;
                        state           <= ST_STEP_REQ;
                    end
                end

                // 每个 Step 共 9 word：8 个 Trigger Mask + 1 个 Delay；同步 RAM 仍采用 REQ/LOAD 两拍读取。
                ST_STEP_REQ: begin
                    state <= ST_STEP_LOAD;
                end

                ST_STEP_LOAD: begin
                    if (step_word_index < 4'd8)
                        pending_mask[step_word_index*16 +: 16] <= seq_ram_rd_data;
                    else
                        delay_ms_reg <= seq_ram_rd_data;

                    if (step_word_index == 4'd8) begin
                        state <= ST_SEQ_SCHED;
                    end
                    else begin
                        step_word_index <= step_word_index + 4'd1;
                        state           <= ST_STEP_REQ;
                    end
                end

                // pending_mask 表示本 Step 尚未成功提交的 Ramp Enable；每次只选择一个当前 ready 的 Channel。
                ST_SEQ_SCHED: begin
                    o_cmd_valid <= 1'b0;

                    if (pending_mask == 128'd0) begin
                        delay_ms_cnt  <= 16'd0;
                        delay_clk_cnt <= 32'd0;

                        if (delay_ms_reg == 16'd0)
                            state <= ST_STEP_ADVANCE;
                        else
                            state <= ST_DELAY;
                    end
                    else if (seq_select_valid) begin
                        o_cmd_bus_id    <= seq_select_bus;
                        o_cmd_device_id <= seq_select_device;
                        o_cmd_reg_addr  <= REG_RAMP_EN;
                        o_cmd_wr_data   <= 16'hFFFF;
                        o_cmd_valid     <= 1'b1;
                        state           <= ST_SEQ_SEND;
                    end
                end
                // 只有 Ramp Enable 握手成功才清对应 pending bit，防止 backpressure 时丢触发。
                ST_SEQ_SEND: begin
                    if (o_cmd_valid && i_cmd_ready) begin
                        o_cmd_valid <= 1'b0;
                        pending_mask[{o_cmd_bus_id, o_cmd_device_id}] <= 1'b0;
                        state <= ST_SEQ_SCHED;
                    end
                end

                // Delay 从本 Step 所有 Trigger 都提交完成后开始计时，不与 Driver 命令派发重叠。
                ST_DELAY: begin
                    if (delay_clk_cnt >= CLK_PER_MS - 1) begin
                        delay_clk_cnt <= 32'd0;

                        if (delay_ms_cnt == delay_ms_reg - 16'd1) begin
                            state <= ST_STEP_ADVANCE;
                        end
                        else begin
                            delay_ms_cnt <= delay_ms_cnt + 16'd1;
                        end
                    end
                    else begin
                        delay_clk_cnt <= delay_clk_cnt + 32'd1;
                    end
                end

                // 当前 Step 的 Trigger 与 Delay 都结束后，再推进到下一条 9-word Step；最后一条完成后产生 done。
                ST_STEP_ADVANCE: begin
                    if (step_index == step_count_reg - 16'd1) begin
                        o_seq_busy <= 1'b0;
                        o_seq_done <= 1'b1;
                        state      <= ST_IDLE;
                    end
                    else begin
                        step_index      <= step_index + 16'd1;
                        step_base_addr  <= step_base_addr + 11'd9;
                        step_word_index <= 4'd0;
                        pending_mask    <= 128'd0;
                        state           <= ST_STEP_REQ;
                    end
                end

                default: begin
                    state        <= ST_IDLE;
                    o_seq_busy   <= 1'b0;
                    o_cmd_valid  <= 1'b0;
                    pending_mask <= 128'd0;
                end
            endcase
        end
    end
end

endmodule
