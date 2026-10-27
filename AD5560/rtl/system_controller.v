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

    // 停止提交确认与响应排空；busy=0 表示模块已退出执行。
    input  wire        i_cfg_busy,
    input  wire        i_seq_busy,
    input  wire        i_alarm_busy,
    input  wire [7:0]  i_seq_read_pending,
    input  wire [7:0]  i_driver_rsp_valid,
    output wire        o_cmd_enable,

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

localparam [3:0] ST_DRAIN = 4'd9;
reg [3:0] state;
reg [1:0] drain_owner;
reg [3:0] drain_next;
reg       drain_quiet;
wire      owner_stopped;
wire      pool_quiet;
assign owner_stopped = (drain_owner == SEL_CONFIG) ? !i_cfg_busy :
                       (drain_owner == SEL_SEQUENCE) ? (!i_seq_busy && (i_seq_read_pending == 0)) :
                       !i_alarm_busy;
assign pool_quiet = (i_driver_ready == 8'hFF) && (i_driver_rsp_valid == 8'd0);
// DRAIN 保留响应归属但关闭命令；Top 必须同时门控 valid 和回送 ready。
assign o_cmd_enable = (state == ST_CONFIG) || (state == ST_SEQUENCE) ||
                      (state == ST_ALARM) || (state == ST_ALARM_CLEAR);
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

        ST_DRAIN:
            o_sel_id = drain_owner;

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
        drain_owner            <= SEL_NONE;
        drain_next             <= ST_IDLE;
        drain_quiet            <= 1'b0;
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
            if ((state == ST_CONFIG) || ((state == ST_DRAIN) && (drain_owner == SEL_CONFIG)))
                o_cfg_abort <= 1'b1;

            if ((state == ST_SEQUENCE) || ((state == ST_DRAIN) && (drain_owner == SEL_SEQUENCE)))
                o_seq_abort <= 1'b1;

            if ((state == ST_ALARM) || (state == ST_ALARM_CLEAR) ||
                ((state == ST_DRAIN) && (drain_owner == SEL_ALARM)))
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
                // Config 执行期间 ALARM 可抢占：先 abort Config，排空后切到 Alarm Scan，不恢复旧配置流程。
                ST_CONFIG: begin
                    if (i_alarm != 8'd0) begin
                        o_alarm_vector <= i_alarm;
                        o_cfg_abort    <= 1'b1;
                        drain_owner    <= SEL_CONFIG;
                        drain_next     <= ST_ALARM;
                        drain_quiet    <= 1'b0;
                        state          <= ST_DRAIN;
                    end
                    else if (i_cfg_done) begin
                        drain_owner <= SEL_CONFIG;
                        drain_next  <= ST_READY;
                        drain_quiet <= 1'b0;
                        state       <= ST_DRAIN;
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

                // Sequence 执行期间 ALARM 可抢占：abort PSE 后排空 Driver，再启动扫描，旧上下电流程不恢复。
                ST_SEQUENCE: begin
                    if (i_alarm != 8'd0) begin
                        o_alarm_vector <= i_alarm;
                        o_seq_abort    <= 1'b1;
                        drain_owner    <= SEL_SEQUENCE;
                        drain_next     <= ST_ALARM;
                        drain_quiet    <= 1'b0;
                        state          <= ST_DRAIN;
                    end
                    else if (i_seq_done) begin
                        // done 只表示业务已停止派发，最后一个 Step 的 Driver 仍可能忙。
                        drain_owner <= SEL_SEQUENCE;
                        drain_next  <= ST_READY;
                        drain_quiet <= 1'b0;
                        state       <= ST_DRAIN;
                    end
                end

                ST_ALARM: begin
                    if (i_alarm_done) begin
                        // Alarm Scan 只负责定位并保存故障；完成后进入 FAULT_HANDLE，等待上层完成故障处理再发 Clear。
                        drain_owner <= SEL_ALARM;
                        drain_next  <= ST_FAULT_HANDLE;
                        drain_quiet <= 1'b0;
                        state       <= ST_DRAIN;
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
                        drain_owner <= SEL_ALARM;
                        drain_next  <= clear_return_ready ? ST_READY : ST_IDLE;
                        drain_quiet <= 1'b0;
                        state       <= ST_DRAIN;
                    end
                end

                // 旧业务先停止；已接受的事务（含 abort 同沿握手）由 Driver 自行完成。
                ST_DRAIN: begin
                    // 即使原先为正常完成，排空期间出现的 ALARM 也锁存并优先处理。
                    if ((drain_owner != SEL_ALARM) && (i_alarm != 8'd0)) begin
                        o_alarm_vector <= (drain_next == ST_ALARM) ?
                                          (o_alarm_vector | i_alarm) : i_alarm;
                        drain_next <= ST_ALARM;
                    end
                    drain_quiet <= owner_stopped && pool_quiet;
                    if (drain_quiet && owner_stopped && pool_quiet) begin
                        if ((drain_owner != SEL_ALARM) &&
                            ((drain_next == ST_ALARM) || (i_alarm != 8'd0))) begin
                            o_alarm_start <= 1'b1;
                            state <= ST_ALARM;
                        end
                        else begin
                            state <= drain_next;
                        end
                        drain_quiet <= 1'b0;
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
                    if (pool_quiet && !i_cfg_busy && !i_seq_busy && !i_alarm_busy &&
                        (i_seq_read_pending == 8'd0)) begin
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
