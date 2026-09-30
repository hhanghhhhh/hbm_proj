`timescale 1ns/1ps

/*
 * 模块说明
 *
 * 功能：
 * - 控制 Config、Power Sequence、Alarm Handler 的启动/中止和业务通路选择。
 * - 锁存 8 路 Driver bus_fault，并完成 Driver fault clear 与系统 fault reset。
 *
 * 关键约束：
 * - 优先级：bus_fault > ALARM > 当前正常流程。
 * - ALARM 扫描完成后进入 FAULT_HANDLE，不恢复被中断的 Config/Sequence。
 * - Driver fault clear 只清底层 sticky fault；系统 fault_vector 保持到 fault_reset。
 * - fault_reset 仅在 FAULT 有效，并等待 8 个 Driver 全 ready 后回 IDLE。
 */

module system_controller (
    input  wire        i_clk,
    input  wire        i_rst_n,

    // Host / command control
    input  wire        i_cfg_start_req,
    input  wire        i_seq_start_req,
    input  wire        i_seq_mode,
    input  wire        i_alarm_clear_req,
    input  wire        i_alarm_clear_all,
    input  wire        i_fault_reset,
    // Module completion
    input  wire        i_cfg_done,
    input  wire        i_seq_done,
    input  wire        i_alarm_done,
    input  wire        i_alarm_clear_done,

    // Device / Driver status
    input  wire [7:0]  i_alarm,
    input  wire [7:0]  i_driver_bus_fault,
    input  wire [7:0]  i_driver_ready,

    // Business module select
    output reg  [1:0]  o_sel_id,

    // Config Manager control
    output reg         o_cfg_start,
    output reg         o_cfg_abort,

    // Power Sequence Engine control
    output reg         o_seq_start,
    output reg         o_seq_mode,
    output reg         o_seq_abort,

    // Alarm Handler control
    output reg         o_alarm_start,
    output reg  [7:0]  o_alarm_vector,
    output reg         o_alarm_abort,
    output reg         o_alarm_clear_start,
    output reg         o_alarm_clear_all,
    // Driver / system fault
    output reg  [7:0]  o_driver_fault_clear,
    output reg  [7:0]  o_fault_vector_latched
);

//-------------------------------------------------------------------
// 业务通路选择：System Controller 只选择当前业务模块，不参与具体 BUS 仲裁。
//-------------------------------------------------------------------
localparam [1:0] SEL_NONE     = 2'd0;
localparam [1:0] SEL_CONFIG   = 2'd1;
localparam [1:0] SEL_SEQUENCE = 2'd2;
localparam [1:0] SEL_ALARM    = 2'd3;

//-------------------------------------------------------------------
// System states
//-------------------------------------------------------------------
localparam [3:0] ST_IDLE             = 4'd0;
localparam [3:0] ST_CONFIG           = 4'd1;
localparam [3:0] ST_READY            = 4'd2;
localparam [3:0] ST_SEQUENCE         = 4'd3;
localparam [3:0] ST_ALARM            = 4'd4;
localparam [3:0] ST_FAULT_HANDLE     = 4'd5;
localparam [3:0] ST_ALARM_CLEAR      = 4'd6;
localparam [3:0] ST_FAULT            = 4'd7;
localparam [3:0] ST_FAULT_RESET_WAIT = 4'd8;

reg [3:0] state;
reg       clear_return_ready;
wire [7:0] new_fault_vector;
assign new_fault_vector = i_driver_bus_fault & ~o_fault_vector_latched;

//-------------------------------------------------------------------
// sel_id 完全由系统状态决定；FAULT/IDLE/READY 等状态不允许业务模块占用公共 Driver 通路。
//-------------------------------------------------------------------
always @(*) begin
    case (state)
        ST_CONFIG:
            o_sel_id = SEL_CONFIG;

        ST_SEQUENCE:
            o_sel_id = SEL_SEQUENCE;

        ST_ALARM,
        ST_ALARM_CLEAR:
            o_sel_id = SEL_ALARM;

        default:
            o_sel_id = SEL_NONE;
    endcase
end

//-------------------------------------------------------------------
// 系统控制主流程：正常业务互斥执行；ALARM 可抢占 Config/Sequence；Driver fault 始终具有最高优先级。
//-------------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        state                  <= ST_IDLE;
        clear_return_ready     <= 1'b0;
        o_cfg_start            <= 1'b0;
        o_cfg_abort            <= 1'b0;
        o_seq_start            <= 1'b0;
        o_seq_mode             <= 1'b0;
        o_seq_abort            <= 1'b0;
        o_alarm_start          <= 1'b0;
        o_alarm_vector         <= 8'd0;
        o_alarm_abort          <= 1'b0;
        o_alarm_clear_start    <= 1'b0;
        o_alarm_clear_all      <= 1'b0;
        o_driver_fault_clear   <= 8'd0;
        o_fault_vector_latched <= 8'd0;
    end
    else begin
        // pulse 类控制信号默认清零。
        o_cfg_start          <= 1'b0;
        o_cfg_abort          <= 1'b0;
        o_seq_start          <= 1'b0;
        o_seq_abort          <= 1'b0;
        o_alarm_start        <= 1'b0;
        o_alarm_abort        <= 1'b0;
        o_alarm_clear_start  <= 1'b0;
        o_driver_fault_clear <= 8'd0;

        // 只对“新出现”的 fault bit 发一次 Driver clear，同时把系统 fault 向量保持到显式 fault_reset。
        if (new_fault_vector != 8'd0) begin
            o_fault_vector_latched <= o_fault_vector_latched |
                                      i_driver_bus_fault;
            o_driver_fault_clear   <= new_fault_vector;
            // 进入 FAULT 前中止当前业务模块；已经被 Driver 接收的底层事务不再撤销。
            if (state == ST_CONFIG)
                o_cfg_abort <= 1'b1;

            if (state == ST_SEQUENCE)
                o_seq_abort <= 1'b1;

            if ((state == ST_ALARM) || (state == ST_ALARM_CLEAR))
                o_alarm_abort <= 1'b1;

            state <= ST_FAULT;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    // IDLE 下的 clear_all 用于初始化预清除，允许压过当前 ALARM 电平，避免历史告警先触发扫描。
                    if (i_alarm_clear_req && i_alarm_clear_all) begin
                        clear_return_ready  <= 1'b0;
                        o_alarm_clear_all   <= 1'b1;
                        o_alarm_clear_start <= 1'b1;
                        state               <= ST_ALARM_CLEAR;
                    end
                    else if (i_alarm != 8'd0) begin
                        o_alarm_vector <= i_alarm;
                        o_alarm_start  <= 1'b1;
                        state          <= ST_ALARM;
                    end
                    else if (i_cfg_start_req) begin
                        o_cfg_start <= 1'b1;
                        state       <= ST_CONFIG;
                    end
                    else if (i_alarm_clear_req) begin
                        clear_return_ready  <= 1'b0;
                        o_alarm_clear_all   <= i_alarm_clear_all;
                        o_alarm_clear_start <= 1'b1;
                        state               <= ST_ALARM_CLEAR;
                    end
                end
                // Config 执行期间 ALARM 可抢占：先 abort Config，再立即切到 Alarm Scan，不恢复旧配置流程。
                ST_CONFIG: begin
                    if (i_alarm != 8'd0) begin
                        o_alarm_vector <= i_alarm;
                        o_cfg_abort    <= 1'b1;
                        o_alarm_start  <= 1'b1;
                        state          <= ST_ALARM;
                    end
                    else if (i_cfg_done) begin
                        state <= ST_READY;
                    end
                end

                // READY 接受正常运行命令；当前优先级为 ALARM > Sequence > Config > 普通 Clear。
                ST_READY: begin
                    if (i_alarm != 8'd0) begin
                        o_alarm_vector <= i_alarm;
                        o_alarm_start  <= 1'b1;
                        state          <= ST_ALARM;
                    end
                    else if (i_seq_start_req) begin
                        o_seq_mode  <= i_seq_mode;
                        o_seq_start <= 1'b1;
                        state       <= ST_SEQUENCE;
                    end
                    else if (i_cfg_start_req) begin
                        o_cfg_start <= 1'b1;
                        state       <= ST_CONFIG;
                    end
                    else if (i_alarm_clear_req) begin
                        clear_return_ready  <= 1'b1;
                        o_alarm_clear_all   <= i_alarm_clear_all;
                        o_alarm_clear_start <= 1'b1;
                        state               <= ST_ALARM_CLEAR;
                    end
                end

                // Sequence 执行期间 ALARM 可抢占：abort PSE 后启动扫描，旧上下电流程不恢复。
                ST_SEQUENCE: begin
                    if (i_alarm != 8'd0) begin
                        o_alarm_vector <= i_alarm;
                        o_seq_abort    <= 1'b1;
                        o_alarm_start  <= 1'b1;
                        state          <= ST_ALARM;
                    end
                    else if (i_seq_done) begin
                        // 正常 Sequence 完成后回 READY，可继续接受下一条业务命令。
                        state <= ST_READY;
                    end
                end

                ST_ALARM: begin
                    if (i_alarm_done) begin
                        // Alarm Scan 只负责定位并保存故障；完成后进入 FAULT_HANDLE，等待上层完成故障处理再发 Clear。
                        state <= ST_FAULT_HANDLE;
                    end
                end

                ST_FAULT_HANDLE: begin
                    if (i_alarm_clear_req) begin
                        clear_return_ready  <= 1'b0;
                        o_alarm_clear_all   <= i_alarm_clear_all;
                        o_alarm_clear_start <= 1'b1;
                        state               <= ST_ALARM_CLEAR;
                    end
                end

                // Clear 完成后的返回位置由启动来源决定：READY 发起则回 READY，故障处理/初始化发起则回 IDLE。
                ST_ALARM_CLEAR: begin
                    if (i_alarm_clear_done) begin
                        if (clear_return_ready)
                            state <= ST_READY;
                        else
                            state <= ST_IDLE;
                    end
                end

                // 系统 fault 已锁存；只有显式 fault_reset 才开始恢复流程，且不会恢复被中断的旧业务。
                ST_FAULT: begin
                    if (i_fault_reset) begin
                        state <= ST_FAULT_RESET_WAIT;
                    end
                end

                // Driver clear 后仍需等 8 路全部 ready，确认底层已恢复，再清系统 fault_vector 并回 IDLE。
                ST_FAULT_RESET_WAIT: begin
                    if (i_driver_ready == 8'hFF) begin
                        o_fault_vector_latched <= 8'd0;
                        state                  <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
end

endmodule
