`timescale 1ns/1ps

/*
 * 模块说明
 *
 * 功能：
 * - 根据锁存的 ALARM BUS 向量扫描对应 AD5560，并保存非零 Alarm Status。
 * - Alarm Clear 支持按最近一次 device_fault_vector 清除，或 clear_all 全部清除。
 *
 * 关键数据：
 * - Result RAM：word0=FAULT_COUNT，word1=ALARM_BUS_VECTOR，后续每个故障占 2 word。
 * - Record ID：{Reserved[8:0], BUS_ID[2:0], DEVICE_ID[3:0]}。
 *
 * 关键约束：
 * - 扫描只读 0x43，Clear 只读 0x44；两者都是 READ，必须等待 rsp_valid。
 * - 每条置位 ALARM BUS 固定扫描 DEV0~DEV15；未报警 BUS 跳过。
 * - 已提交给 Driver 的 READ 不会被 abort 撤销，abort 后晚到 rsp_valid 直接忽略。
 */

module alarm_handler (
    input  wire         i_clk,
    input  wire         i_rst_n,

    // System control
    input  wire         i_alarm_start,
    input  wire [7:0]   i_alarm_vector,
    input  wire         i_alarm_abort,
    input  wire         i_alarm_clear_start,
    input  wire         i_alarm_clear_all,
    output reg          o_alarm_busy,
    output reg          o_alarm_done,
    output reg          o_alarm_clear_busy,
    output reg          o_alarm_clear_done,
    output reg  [127:0] o_device_fault_vector,

    // Result RAM read interface
    input  wire [8:0]   i_alarm_result_rd_addr,
    output wire [15:0]  o_alarm_result_rd_data,

    // Common Driver command interface
    output reg          o_cmd_valid,
    input  wire         i_cmd_ready,
    output wire         o_cmd_rw,
    output reg  [2:0]   o_cmd_bus_id,
    output reg  [3:0]   o_cmd_device_id,
    output reg  [6:0]   o_cmd_reg_addr,
    output wire [15:0]  o_cmd_wr_data,

    // Driver read response
    input  wire         i_rsp_valid,
    input  wire [15:0]  i_rsp_rd_data
);

//-------------------------------------------------------------------
// Constants
//-------------------------------------------------------------------
localparam [6:0] REG_ALARM_STATUS = 7'h43;
localparam [6:0] REG_ALARM_CLEAR  = 7'h44;
localparam [3:0] ST_IDLE             = 4'd0;
localparam [3:0] ST_SCAN_FIND_BUS    = 4'd1;
localparam [3:0] ST_SCAN_SEND        = 4'd2;
localparam [3:0] ST_SCAN_WAIT_RSP    = 4'd3;
localparam [3:0] ST_SCAN_SAVE_ID     = 4'd4;
localparam [3:0] ST_SCAN_SAVE_STATUS = 4'd5;
localparam [3:0] ST_SCAN_ADVANCE     = 4'd6;
localparam [3:0] ST_SCAN_SAVE_COUNT  = 4'd7;
localparam [3:0] ST_SCAN_SAVE_VECTOR = 4'd8;
localparam [3:0] ST_CLEAR_FIND       = 4'd9;
localparam [3:0] ST_CLEAR_SEND       = 4'd10;
localparam [3:0] ST_CLEAR_WAIT_RSP   = 4'd11;

reg [3:0] state;

assign o_cmd_rw      = 1'b1;
assign o_cmd_wr_data = 16'h0000;

//-------------------------------------------------------------------
// Scan / Clear 运行上下文：Scan 锁存本轮 ALARM BUS，Clear 锁存清除模式，整个事务过程中不再依赖实时输入。
//-------------------------------------------------------------------
reg [7:0]  alarm_vector_reg;
reg [2:0]  scan_bus_id;
reg [3:0]  scan_device_id;
reg [15:0] scan_status_reg;
reg [7:0]  fault_count;
reg [8:0]  result_write_ptr;
reg [6:0]  clear_channel_id;
reg        clear_all_reg;
//-------------------------------------------------------------------
// Alarm Result RAM：A 口由扫描流程写 Header/Record，B 口供通信侧同步读取最近一次扫描结果。
//-------------------------------------------------------------------
reg         result_ram_wr_en;
reg [8:0]   result_ram_wr_addr;
reg [15:0]  result_ram_wr_data;
wire [15:0] result_ram_rd_data;

assign o_alarm_result_rd_data = result_ram_rd_data;

// B 口持续使能；通信侧改变地址后按同步 RAM 读延迟取得对应 word。
alarm_result_ram u_alarm_result_ram (
    .dia   (result_ram_wr_data),
    .addra (result_ram_wr_addr),
    .cea   (result_ram_wr_en),
    .clka  (i_clk),
    .dob   (result_ram_rd_data),
    .addrb (i_alarm_result_rd_addr),
    .ceb   (1'b1),
    .clkb  (i_clk)
);

//-------------------------------------------------------------------
// Result RAM 写控制：只有非零 status 生成 Record；扫描结束后再写 Header 的 count 和 alarm_vector。
//-------------------------------------------------------------------
always @(*) begin
    result_ram_wr_en   = 1'b0;
    result_ram_wr_addr = 9'd0;
    result_ram_wr_data = 16'd0;
    // abort 具有更高优先级，同周期禁止继续写 RAM，避免终止后的流程留下新的有效记录。
    if (!i_alarm_abort) begin
        case (state)
            ST_SCAN_SAVE_ID: begin
                result_ram_wr_en   = 1'b1;
                result_ram_wr_addr = result_write_ptr;
                result_ram_wr_data = {9'd0, scan_bus_id, scan_device_id};
            end

            ST_SCAN_SAVE_STATUS: begin
                result_ram_wr_en   = 1'b1;
                result_ram_wr_addr = result_write_ptr + 9'd1;
                result_ram_wr_data = scan_status_reg;
            end

            ST_SCAN_SAVE_COUNT: begin
                result_ram_wr_en   = 1'b1;
                result_ram_wr_addr = 9'd0;
                result_ram_wr_data = {8'd0, fault_count};
            end

            ST_SCAN_SAVE_VECTOR: begin
                result_ram_wr_en   = 1'b1;
                result_ram_wr_addr = 9'd1;
                result_ram_wr_data = {8'd0, alarm_vector_reg};
            end

            default: ;
        endcase
    end
end
//-------------------------------------------------------------------
// 主流程分两条独立路径：Scan 逐 BUS/Device READ 0x43 并记录故障；Clear 按目标逐 Device READ 0x44。
//-------------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        state                 <= ST_IDLE;
        alarm_vector_reg      <= 8'd0;
        scan_bus_id           <= 3'd0;
        scan_device_id        <= 4'd0;
        scan_status_reg       <= 16'd0;
        fault_count           <= 8'd0;
        result_write_ptr      <= 9'd2;
        clear_channel_id      <= 7'd0;
        clear_all_reg         <= 1'b0;

        o_alarm_busy          <= 1'b0;
        o_alarm_done          <= 1'b0;
        o_alarm_clear_busy    <= 1'b0;
        o_alarm_clear_done    <= 1'b0;
        o_device_fault_vector <= 128'd0;

        o_cmd_valid           <= 1'b0;
        o_cmd_bus_id          <= 3'd0;
        o_cmd_device_id       <= 4'd0;
        o_cmd_reg_addr        <= 7'd0;
    end
    else begin
        o_alarm_done       <= 1'b0;
        o_alarm_clear_done <= 1'b0;
        // abort 停止后续扫描/清除并撤销尚未握手的 valid；已经交给 Driver 的 READ 仍会在后台结束，晚到 rsp 在 IDLE 被忽略。
        if (i_alarm_abort && (o_alarm_busy || o_alarm_clear_busy)) begin
            state              <= ST_IDLE;
            o_alarm_busy       <= 1'b0;
            o_alarm_clear_busy <= 1'b0;
            o_cmd_valid        <= 1'b0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    o_alarm_busy       <= 1'b0;
                    o_alarm_clear_busy <= 1'b0;
                    o_cmd_valid        <= 1'b0;

                    if (i_alarm_start) begin
                        alarm_vector_reg      <= i_alarm_vector;
                        scan_bus_id           <= 3'd0;
                        scan_device_id        <= 4'd0;
                        fault_count           <= 8'd0;
                        result_write_ptr      <= 9'd2;
                        o_device_fault_vector <= 128'd0;
                        o_alarm_busy          <= 1'b1;
                        state                 <= ST_SCAN_FIND_BUS;
                    end
                    else if (i_alarm_clear_start) begin
                        clear_channel_id   <= 7'd0;
                        clear_all_reg      <= i_alarm_clear_all;
                        o_alarm_clear_busy <= 1'b1;
                        state              <= ST_CLEAR_FIND;
                    end
                end
                // 从锁存的 alarm_vector 中寻找下一个需要扫描的 BUS；未置位 BUS 直接跳过。
                ST_SCAN_FIND_BUS: begin
                    o_cmd_valid <= 1'b0;

                    if (alarm_vector_reg[scan_bus_id]) begin
                        scan_device_id <= 4'd0;
                        state          <= ST_SCAN_SEND;
                    end
                    else if (scan_bus_id == 3'd7) begin
                        state <= ST_SCAN_SAVE_COUNT;
                    end
                    else begin
                        scan_bus_id <= scan_bus_id + 3'd1;
                    end
                end

                // 提交当前 Device 的 Alarm Status READ。valid/ready 只表示请求已进入 Driver，尚不能推进 Device。
                ST_SCAN_SEND: begin
                    o_cmd_bus_id    <= scan_bus_id;
                    o_cmd_device_id <= scan_device_id;
                    o_cmd_reg_addr  <= REG_ALARM_STATUS;
                    o_cmd_valid     <= 1'b1;

                    if (o_cmd_valid && i_cmd_ready) begin
                        o_cmd_valid <= 1'b0;
                        state       <= ST_SCAN_WAIT_RSP;
                    end
                end

                // 必须等 rsp_valid 才能判定当前 Device：status=0 直接前进，非零则先写 Result Record。
                ST_SCAN_WAIT_RSP: begin
                    if (i_rsp_valid) begin
                        scan_status_reg <= i_rsp_rd_data;
                        if (i_rsp_rd_data != 16'd0) begin
                            o_device_fault_vector[
                                {scan_bus_id, scan_device_id}
                            ] <= 1'b1;
                            state <= ST_SCAN_SAVE_ID;
                        end
                        else begin
                            state <= ST_SCAN_ADVANCE;
                        end
                    end
                end

                ST_SCAN_SAVE_ID: begin
                    // Result RAM 每拍只写 1 个 16-bit word：本拍写 Record ID，下一状态再写 Alarm Status。
                    state <= ST_SCAN_SAVE_STATUS;
                end

                ST_SCAN_SAVE_STATUS: begin
                    fault_count      <= fault_count + 8'd1;
                    result_write_ptr <= result_write_ptr + 9'd2;
                    state            <= ST_SCAN_ADVANCE;
                end

                // 当前 Device 处理完成后推进 DEV；DEV15 结束时再切到下一个报警 BUS。
                ST_SCAN_ADVANCE: begin
                    if (scan_device_id == 4'd15) begin
                        if (scan_bus_id == 3'd7) begin
                            state <= ST_SCAN_SAVE_COUNT;
                        end
                        else begin
                            scan_bus_id    <= scan_bus_id + 3'd1;
                            scan_device_id <= 4'd0;
                            state          <= ST_SCAN_FIND_BUS;
                        end
                    end
                    else begin
                        scan_device_id <= scan_device_id + 4'd1;
                        state          <= ST_SCAN_SEND;
                    end
                end

                ST_SCAN_SAVE_COUNT: begin
                    // 全部目标 BUS 扫描结束后发布 Header；先写 FAULT_COUNT，下一拍写本轮 ALARM_BUS_VECTOR。
                    state <= ST_SCAN_SAVE_VECTOR;
                end

                ST_SCAN_SAVE_VECTOR: begin
                    o_alarm_busy <= 1'b0;
                    o_alarm_done <= 1'b1;
                    state        <= ST_IDLE;
                end

                // Clear 在 Channel0~127 中寻找目标：clear_all 清全部，否则只处理最近一次 fault_vector 置位的 Device。
                ST_CLEAR_FIND: begin
                    o_cmd_valid <= 1'b0;

                    if (clear_all_reg || o_device_fault_vector[clear_channel_id]) begin
                        state <= ST_CLEAR_SEND;
                    end
                    else if (clear_channel_id == 7'd127) begin
                        o_alarm_clear_busy <= 1'b0;
                        o_alarm_clear_done <= 1'b1;
                        state              <= ST_IDLE;
                    end
                    else begin
                        clear_channel_id <= clear_channel_id + 7'd1;
                    end
                end

                // 0x44 也是 READ 事务；提交后必须等待 rsp_valid，不能仅凭 valid/ready 就认为清除完成。
                ST_CLEAR_SEND: begin
                    o_cmd_bus_id    <= clear_channel_id[6:4];
                    o_cmd_device_id <= clear_channel_id[3:0];
                    o_cmd_reg_addr  <= REG_ALARM_CLEAR;
                    o_cmd_valid     <= 1'b1;

                    if (o_cmd_valid && i_cmd_ready) begin
                        o_cmd_valid <= 1'b0;
                        state       <= ST_CLEAR_WAIT_RSP;
                    end
                end

                // 当前 Device 的 0x44 response 返回后才推进到下一 Channel；最后一个目标完成时产生 clear_done。
                ST_CLEAR_WAIT_RSP: begin
                    if (i_rsp_valid) begin
                        if (clear_channel_id == 7'd127) begin
                            o_alarm_clear_busy <= 1'b0;
                            o_alarm_clear_done <= 1'b1;
                            state              <= ST_IDLE;
                        end
                        else begin
                            clear_channel_id <= clear_channel_id + 7'd1;
                            state            <= ST_CLEAR_FIND;
                        end
                    end
                end

                default: begin
                    state              <= ST_IDLE;
                    o_alarm_busy       <= 1'b0;
                    o_alarm_clear_busy <= 1'b0;
                    o_cmd_valid        <= 1'b0;
                end
            endcase
        end
    end
end

endmodule
