`timescale 1ns / 1ps
`include "jwh6374_common_defs.vh"

/*
 * Module Contract
 *
 * 模块职责：
 * - 在一条物理 I2C 总线上顺序执行单颗 JWH6374 的配置或在线访问记录表。
 * - 可在配置成功后依次固化三个 PAGE，轮询 MTP_BUSY 并读取 MTP CRC。
 * - 空闲时按使能位图轮询 8 个设备的双 Rail 遥测，并调查 SMB_ALERT 下降沿。
 * - 不负责：保存配置/结果/遥测 RAM、生成通信响应或跨物理总线仲裁。
 *
 * 输入事务：
 * - o_cfg_ready=1 时，i_cfg_start=1 的上升沿采样模式、设备号、记录数和固化标志。
 * - 记录数必须为 1..P_MAX_CFG_RECORDS；配置模式还要求 i_config_allowed=1。
 * - 32 位记录字段为 PAGE[31:30]、OP[29:27]、COMMAND[26:19]、DATA[18:3]、RESERVED[2:0]。
 * - RESERVED 必须为 0，PAGE/OP 必须合法，记录不得直接写 PAGE 命令 00h 或 STORE 15h。
 *
 * 输出事务：
 * - 每条成功记录向同索引结果 RAM 写 16 位结果；读操作写回数据，写/Send 写 0。
 * - 任务结束后保持 o_cfg_resp_valid 及错误信息，直到与 i_cfg_resp_ready 握手。
 * - 遥测轮询把状态/电压/电流及总线错误写到 o_tel_wr_*；每次只执行一个项目后让出仲裁。
 * - 告警报告保持支路号和设备位图，直到 valid/ready 握手。
 *
 * 关键时序：
 * - 空闲仲裁优先级固定为配置/在线任务、已锁存告警、后台遥测。
 * - 配置 RAM 为同步读：读使能一拍，等待一拍后捕获记录。
 * - 下层总线请求 valid 保持到 ready；响应由 controller 的 valid 事件返回。
 * - 配置且 store_after=1 时，普通记录全部成功后依次执行 PAGE0/1/2 的 STORE、忙轮询和 CRC 读。
 *
 * 异常与恢复：
 * - reset：异步低有效，清除在途任务、事件、错误信息、告警锁存和总线请求。
 * - clear：同步回到空闲并撤销对外 valid/使能；告警同步链和待处理位同时清零。
 * - 记录、许可、数量、总线或 MTP 超时错误终止当前任务，并在配置响应中报告首个失败索引。
 * - MTP_BUSY 轮询期间仅地址/命令/数据 NACK 可重试，其他总线错误直接结束任务。
 *
 * 使用约束：
 * - 配置模式仅在外部确认设备允许配置时启动；在线模式不检查 i_config_allowed。
 * - i_cfg_* 参数必须从启动握手到被采样保持稳定，RAM 内容在任务执行期间不得覆盖。
 * - 本参考实现遥测设备号固定轮询 0..7；配置设备号仍使用完整 6 位输入。
 * - JWH 地址为 P_JWH_ADDR_BASE 加 device_id 低三位，device_id 高三位选择 TCA 支路。
 *
 * 参考：
 * - DUT_POWER_CONTROL_FLOW.md：配置、固化、遥测和告警的系统流程。
 * - DUT_POWER_CONTROL.md：JWH6374 访问约束和错误处理。
 */

module jwh6374_bus_service_demo_8 #(
    parameter integer P_SYS_CLK_FREQ          = 100_000_000,
    parameter integer P_I2C_BAUD_RATE         = 400_000,
    parameter integer P_I2C_TIMEOUT_MS        = 35,
    parameter [6:0]   P_TCA_ADDR              = 7'h70,
    parameter [31:0]  P_TCA_DEAD_CYCLES       = 32'd500,
    parameter         P_PEC_ENABLE            = 1'b1,
    parameter         P_TCA_ENABLE            = 1'b1,
    parameter [6:0]   P_JWH_ADDR_BASE         = 7'h60,
    parameter integer P_MAX_CFG_RECORDS       = 1024,
    parameter integer P_MTP_POLL_INTERVAL_MS  = 1,
    parameter integer P_MTP_TIMEOUT_MS        = 500
)(
    input  wire         i_clk,
    input  wire         i_rst_n,
    input  wire         i_clear,

    // 单颗器件顺序任务。配置模式要求EN关闭；在线模式允许Rail运行时访问。
    input  wire         i_config_allowed,
    input  wire         i_cfg_start,
    output wire         o_cfg_ready,
    input  wire         i_cfg_config_mode,   // 1=配置，0=在线访问
    input  wire [5:0]   i_cfg_device_id,
    input  wire [10:0]  i_cfg_record_count,
    input  wire         i_cfg_store_after,

    output reg          o_cfg_resp_valid,
    input  wire         i_cfg_resp_ready,
    output reg          o_cfg_resp_error,
    output reg  [3:0]   o_cfg_sys_error_code,
    output reg  [4:0]   o_cfg_bus_error_code,
    output reg  [9:0]   o_cfg_error_index,
    output reg  [15:0]  o_cfg_last_mtp_crc,

    // 单颗任务命令RAM，同步读，建议1024 x 32 bit。
    output reg          o_cfg_ram_rd_en,
    output reg  [9:0]   o_cfg_ram_rd_addr,
    input  wire [31:0]  i_cfg_ram_rd_data,

    // 任务结果RAM：地址与命令索引一致，每项固定16 bit。
    output reg          o_cfg_result_wr_en,
    output reg  [9:0]   o_cfg_result_wr_addr,
    output reg  [15:0]  o_cfg_result_wr_data,

    // 最新遥测 RAM：{device[5:0], rail, item[1:0]}，共 512 项。
    input  wire [15:0]  i_telemetry_enable,
    output reg          o_tel_wr_en,
    output reg  [8:0]   o_tel_wr_addr,
    output reg  [31:0]  o_tel_wr_data,

    // 每个 TCA 支路一根低有效 SMB_ALERT#。
    input  wire [7:0]   i_smb_alert_n,
    output reg          o_alert_report_valid,
    input  wire         i_alert_report_ready,
    output reg  [2:0]   o_alert_report_channel,
    output reg  [7:0]   o_alert_report_device_mask,

    output reg  [5:0]   o_current_device_id,
    output reg  [5:0]   o_debug_state,
    output wire [3:0]   o_debug_bus_state,
    output wire         o_debug_tca_enabled,
    output wire         o_debug_page_cache_valid,
    output wire [7:0]   o_debug_page_cache_page,
    output wire         o_debug_request_needs_page,
    output wire [2:0]   o_debug_active_channel,
    output wire         o_debug_active_channel_valid,

    input  wire         i_scl_i,
    output wire         o_scl_o,
    output wire         o_scl_t,
    input  wire         i_sda_i,
    output wire         o_sda_o,
    output wire         o_sda_t
);

    localparam [3:0] SYS_ERR_NONE        = 4'd0,
                     SYS_ERR_EN_NOT_OFF  = 4'd1,
                     SYS_ERR_CFG_COUNT   = 4'd2,
                     SYS_ERR_BUS         = 4'd3,
                     SYS_ERR_RECORD      = 4'd4,
                     SYS_ERR_MTP_TIMEOUT = 4'd5;

    localparam [1:0] TEL_STATUS = 2'd0,
                     TEL_VOUT   = 2'd1,
                     TEL_IOUT   = 2'd2;

    // 状态分组：IDLE；公共总线访问；配置；MTP固化；遥测；告警。
    localparam [5:0] ST_IDLE              = 6'd0,
                     ST_ACCESS_REQUEST    = 6'd1,
                     ST_ACCESS_RESPONSE   = 6'd2,
                     ST_CFG_BEGIN         = 6'd3,
                     ST_CFG_RAM_REQUEST   = 6'd4,
                     ST_CFG_RAM_WAIT      = 6'd5,
                     ST_CFG_RAM_CAPTURE   = 6'd6,
                     ST_CFG_DISPATCH      = 6'd7,
                     ST_CFG_EVALUATE      = 6'd8,
                     ST_CFG_ADVANCE       = 6'd9,
                     ST_CFG_RESPONSE      = 6'd10,
                     ST_MTP_POLL_WAIT     = 6'd11,
                     ST_MTP_POLL_PREP     = 6'd12,
                     ST_MTP_POLL_EVAL     = 6'd13,
                     ST_MTP_CRC_PREP      = 6'd14,
                     ST_MTP_CRC_EVAL      = 6'd15,
                     ST_MONITOR_CHECK     = 6'd16,
                     ST_MONITOR_PREP      = 6'd17,
                     ST_MONITOR_STORE     = 6'd18,
                     ST_MONITOR_ADVANCE   = 6'd19,
                     ST_ALERT_BEGIN       = 6'd20,
                     ST_ALERT_PREP        = 6'd22,
                     ST_ALERT_EVAL        = 6'd23,
                     ST_ALERT_ADVANCE     = 6'd24,
                     ST_ALERT_REPORT      = 6'd25,
                     ST_STORE_PREP        = 6'd26,
                     ST_STORE_EVAL        = 6'd27,
                     ST_CFG_FINISH        = 6'd28;

    localparam integer CYCLES_PER_MS = P_SYS_CLK_FREQ / 1000;

    reg [5:0] r_state;
    reg [5:0] r_after_access_state;

    reg [5:0]  r_access_device_id;
    reg [7:0]   r_access_page;
    reg [2:0]   r_access_op;
    reg [7:0]   r_access_command;
    reg [15:0]  r_access_write_data;
    reg [15:0]  r_last_bus_data;
    reg         r_last_bus_error;
    reg [4:0]   r_last_bus_error_code;

    reg [5:0]   r_cfg_device_id;
    reg         r_cfg_config_mode;
    reg [10:0]  r_cfg_record_count;
    reg         r_cfg_store_after;
    reg [1:0]   r_store_page;
    reg [9:0]   r_cfg_index;
    reg [1:0]   r_rec_page;
    reg [2:0]   r_rec_op;
    reg [7:0]   r_rec_command;
    reg [15:0]  r_rec_data;
    reg [2:0]   r_rec_reserved;
    reg [47:0]  r_mtp_total_counter;
    reg [47:0]  r_mtp_poll_counter;

    reg [5:0] r_poll_device;
    reg       r_poll_rail;
    reg [1:0] r_poll_item;

    reg [7:0] r_alert_cdc0;
    reg [7:0] r_alert_cdc1;
    reg [7:0] r_alert_prev;
    reg [7:0] r_alert_pending;
    reg [2:0] r_alert_channel;
    reg [7:0] r_alert_found_mask;

    reg        r_bus_req_valid;
    wire       w_bus_req_ready;
    reg [2:0]  r_bus_req_channel;
    reg [6:0]  r_bus_req_dev_addr;
    reg [7:0]  r_bus_req_page;
    reg [2:0]  r_bus_req_op;
    reg [7:0]  r_bus_req_command;
    reg [15:0] r_bus_req_write_data;
    wire       w_bus_resp_valid;
    wire [15:0] w_bus_resp_read_data;
    wire       w_bus_resp_error;
    wire [4:0] w_bus_resp_error_code;

    // service空闲且下层可接收逻辑请求时，允许启动新的上层任务。
    // 总线故障时bus controller仍接收请求，并以错误码10立即响应。
    assign o_cfg_ready = (r_state == ST_IDLE) && w_bus_req_ready;

    function [2:0] f_first_alert_channel;
        input [7:0] i_pending;
        integer k;
        reg found;
        begin
            f_first_alert_channel = 3'd0;
            found = 1'b0;
            for (k = 0; k < 8; k = k + 1) begin
                if (i_pending[k] && !found) begin
                    f_first_alert_channel = k[2:0];
                    found = 1'b1;
                end
            end
        end
    endfunction

    // 异步告警同步并锁存下降沿；报告被接收后清除对应待处理位。
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_alert_cdc0    <= 8'hFF;
            r_alert_cdc1    <= 8'hFF;
            r_alert_prev    <= 8'hFF;
            r_alert_pending <= 8'h00;
        end else if (i_clear) begin
            r_alert_cdc0    <= 8'hFF;
            r_alert_cdc1    <= 8'hFF;
            r_alert_prev    <= 8'hFF;
            r_alert_pending <= 8'h00;
        end else begin
            r_alert_cdc0 <= i_smb_alert_n;
            r_alert_cdc1 <= r_alert_cdc0;
            r_alert_prev <= r_alert_cdc1;
            r_alert_pending <= r_alert_pending |
                               (r_alert_prev & ~r_alert_cdc1);
            if ((r_state == ST_ALERT_REPORT) &&
                o_alert_report_valid && i_alert_report_ready) begin
                r_alert_pending[r_alert_channel] <= 1'b0;
            end
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state                    <= ST_IDLE;
            r_after_access_state       <= ST_IDLE;
            r_access_device_id         <= 6'd0;
            r_access_page              <= 8'd0;
            r_access_op                <= `JWH_OP_SEND_BYTE;
            r_access_command           <= 8'd0;
            r_access_write_data        <= 16'd0;
            r_last_bus_data            <= 16'd0;
            r_last_bus_error           <= 1'b0;
            r_last_bus_error_code      <= 5'd0;
            r_cfg_device_id            <= 6'd0;
            r_cfg_config_mode          <= 1'b1;
            r_cfg_record_count         <= 11'd0;
            r_cfg_store_after          <= 1'b0;
            r_store_page               <= 2'd0;
            r_cfg_index                <= 10'd0;
            r_rec_page                 <= 2'd0;
            r_rec_op                   <= `JWH_OP_SEND_BYTE;
            r_rec_command              <= 8'd0;
            r_rec_data                 <= 16'd0;
            r_rec_reserved             <= 3'd0;
            r_mtp_total_counter        <= 48'd0;
            r_mtp_poll_counter         <= 48'd0;
            r_poll_device              <= 6'd0;
            r_poll_rail                <= 1'b0;
            r_poll_item                <= TEL_STATUS;
            r_alert_channel            <= 3'd0;
            r_alert_found_mask         <= 8'd0;

            o_cfg_resp_valid           <= 1'b0;
            o_cfg_resp_error           <= 1'b0;
            o_cfg_sys_error_code       <= SYS_ERR_NONE;
            o_cfg_bus_error_code       <= 5'd0;
            o_cfg_error_index          <= 10'd0;
            o_cfg_last_mtp_crc         <= 16'd0;
            o_cfg_ram_rd_en            <= 1'b0;
            o_cfg_ram_rd_addr          <= 10'd0;
            o_cfg_result_wr_en         <= 1'b0;
            o_cfg_result_wr_addr       <= 10'd0;
            o_cfg_result_wr_data       <= 16'd0;
            o_tel_wr_en                <= 1'b0;
            o_tel_wr_addr              <= 9'd0;
            o_tel_wr_data              <= 32'd0;
            o_alert_report_valid       <= 1'b0;
            o_alert_report_channel     <= 3'd0;
            o_alert_report_device_mask <= 8'd0;
            o_current_device_id        <= 6'd0;
            o_debug_state              <= ST_IDLE;

            r_bus_req_valid            <= 1'b0;
            r_bus_req_channel          <= 3'd0;
            r_bus_req_dev_addr         <= P_JWH_ADDR_BASE;
            r_bus_req_page             <= 8'd0;
            r_bus_req_op               <= `JWH_OP_SEND_BYTE;
            r_bus_req_command          <= 8'd0;
            r_bus_req_write_data       <= 16'd0;
        end else if (i_clear) begin
            r_state                    <= ST_IDLE;
            o_cfg_resp_valid           <= 1'b0;
            o_cfg_ram_rd_en            <= 1'b0;
            o_cfg_result_wr_en         <= 1'b0;
            o_tel_wr_en                <= 1'b0;
            o_alert_report_valid       <= 1'b0;
            r_bus_req_valid            <= 1'b0;
            o_debug_state              <= ST_IDLE;
        end else begin
            o_cfg_ram_rd_en <= 1'b0;
            o_cfg_result_wr_en <= 1'b0;
            o_tel_wr_en     <= 1'b0;
            o_debug_state   <= r_state;

            case (r_state)
                    // 空闲仲裁：按“寄存器任务 > 告警 > 遥测”启动任务。
                    ST_IDLE: begin
                        r_bus_req_valid <= 1'b0;
                        // 最高优先级：接收单颗器件的配置或在线访问任务。
                        if (i_cfg_start && o_cfg_ready) begin
                            r_cfg_device_id       <= i_cfg_device_id;
                            r_cfg_config_mode     <= i_cfg_config_mode;
                            r_cfg_record_count    <= i_cfg_record_count;
                            r_cfg_store_after     <= i_cfg_store_after;
                            o_current_device_id   <= i_cfg_device_id;
                            o_cfg_resp_error      <= 1'b0;
                            o_cfg_sys_error_code  <= SYS_ERR_NONE;
                            o_cfg_bus_error_code  <= 5'd0;
                            o_cfg_error_index     <= 10'd0;
                            o_cfg_last_mtp_crc    <= 16'd0;
                            r_state <= ST_CFG_BEGIN;
                        // 无配置任务时，优先调查已锁存的SMB_ALERT下降沿。
                        end else if (w_bus_req_ready &&
                                     (|r_alert_pending)) begin
                            r_state <= ST_ALERT_BEGIN;
                        // 最低优先级：利用空闲时间执行一项后台遥测。
                        end else if (w_bus_req_ready &&
                                     (|i_telemetry_enable)) begin
                            r_state <= ST_MONITOR_CHECK;
                        end
                    end

                    // 总线请求：整理目标通道/地址/PMBus参数并完成请求握手。
                    ST_ACCESS_REQUEST: begin
                        r_bus_req_channel    <= r_access_device_id[5:3];
                        r_bus_req_dev_addr   <= P_JWH_ADDR_BASE +
                                                r_access_device_id[2:0];
                        r_bus_req_page       <= r_access_page;
                        r_bus_req_op         <= r_access_op;
                        r_bus_req_command    <= r_access_command;
                        r_bus_req_write_data <= r_access_write_data;
                        r_bus_req_valid      <= 1'b1;
                        // ready/valid握手后撤销请求，防止重复提交。
                        if (r_bus_req_valid && w_bus_req_ready) begin
                            r_bus_req_valid <= 1'b0;
                            r_state         <= ST_ACCESS_RESPONSE;
                        end
                    end

                    // 普通总线响应：锁存结果，再返回调用者指定的评价状态。
                    ST_ACCESS_RESPONSE: begin
                        if (w_bus_resp_valid) begin
                            r_last_bus_data       <= w_bus_resp_read_data;
                            r_last_bus_error      <= w_bus_resp_error;
                            r_last_bus_error_code <= w_bus_resp_error_code;
                            r_state               <= r_after_access_state;
                        end
                    end

                    // 任务入口：配置模式检查EN；两种模式都检查记录数量。
                    ST_CFG_BEGIN: begin
                        // 在线模式不受EN状态限制。
                        if (r_cfg_config_mode && !i_config_allowed) begin
                            o_cfg_resp_error      <= 1'b1;
                            o_cfg_sys_error_code  <= SYS_ERR_EN_NOT_OFF;
                            r_state               <= ST_CFG_RESPONSE;
                        // 记录数必须处于1..P_MAX_CFG_RECORDS范围内。
                        end else if ((r_cfg_record_count == 0) ||
                                     (r_cfg_record_count >
                                      P_MAX_CFG_RECORDS)) begin
                            o_cfg_resp_error      <= 1'b1;
                            o_cfg_sys_error_code  <= SYS_ERR_CFG_COUNT;
                            r_state               <= ST_CFG_RESPONSE;
                        end else begin
                            r_cfg_index <= 10'd0;
                            r_state     <= ST_CFG_RAM_REQUEST;
                        end
                    end

                    // 配置取数请求：向同步配置RAM发出当前记录地址。
                    ST_CFG_RAM_REQUEST: begin
                        o_cfg_ram_rd_en   <= 1'b1;
                        o_cfg_ram_rd_addr <= r_cfg_index;
                        r_state           <= ST_CFG_RAM_WAIT;
                    end

                    // 配置取数等待：为同步RAM保留一个读延迟周期。
                    ST_CFG_RAM_WAIT: begin
                        r_state <= ST_CFG_RAM_CAPTURE;
                    end

                    // 配置记录锁存：拆出PAGE、操作、Command、Data和保留位。
                    ST_CFG_RAM_CAPTURE: begin
                        r_rec_page     <= i_cfg_ram_rd_data[31:30];
                        r_rec_op       <= i_cfg_ram_rd_data[29:27];
                        r_rec_command  <= i_cfg_ram_rd_data[26:19];
                        r_rec_data     <= i_cfg_ram_rd_data[18:3];
                        r_rec_reserved <= i_cfg_ram_rd_data[2:0];
                        r_state        <= ST_CFG_DISPATCH;
                    end

                    // 配置派发：校验记录，并把目标PAGE随请求交给bus controller。
                    ST_CFG_DISPATCH: begin
                        // 任一格式错误均在发起I2C事务前终止本次配置。
                        if ((r_rec_reserved != 3'b000) ||
                            (r_rec_op > `JWH_OP_READ_WORD) ||
                            (r_rec_page > 2'd2) ||
                            // PAGE由bus controller统一管理，RAM禁止直接写00h。
                            (r_rec_command == 8'h00) ||
                            // STORE由i_cfg_store_after统一产生，RAM中禁止15h。
                            ((r_rec_op == `JWH_OP_SEND_BYTE) &&
                             (r_rec_command == 8'h15))) begin
                            o_cfg_resp_error      <= 1'b1;
                            o_cfg_sys_error_code  <= SYS_ERR_RECORD;
                            o_cfg_error_index     <= r_cfg_index;
                            r_state               <= ST_CFG_RESPONSE;
                        end else begin
                            r_access_device_id   <= r_cfg_device_id;
                            // 上层只声明目标PAGE，不再维护器件PAGE状态。
                            r_access_page        <= {6'd0, r_rec_page};
                            r_access_op          <= r_rec_op;
                            r_access_command     <= r_rec_command;
                            r_access_write_data  <= r_rec_data;
                            r_after_access_state <= ST_CFG_EVALUATE;
                            r_state              <= ST_ACCESS_REQUEST;
                        end
                    end

                    // 记录结果：检查错误；成功则写结果RAM并推进。
                    ST_CFG_EVALUATE: begin
                        // 普通配置不自动重试：保留失败记录索引交给上位机处理。
                        if (r_last_bus_error) begin
                            o_cfg_resp_error      <= 1'b1;
                            o_cfg_sys_error_code  <= SYS_ERR_BUS;
                            o_cfg_bus_error_code  <= r_last_bus_error_code;
                            o_cfg_error_index     <= r_cfg_index;
                            r_state               <= ST_CFG_RESPONSE;
                        end else begin
                            o_cfg_result_wr_en   <= 1'b1;
                            o_cfg_result_wr_addr <= r_cfg_index;
                            o_cfg_result_wr_data <= r_last_bus_data;
                            r_state <= ST_CFG_ADVANCE;
                        end
                    end

                    // =========================================================
                    // 可选固化：普通配置全部成功后才执行STORE。
                    // =========================================================
                    // STORE准备：切到当前循环PAGE并发起Send Byte 15h固化命令。
                    ST_STORE_PREP: begin
                        r_access_device_id   <= r_cfg_device_id;
                        r_access_page        <= {6'd0, r_store_page};
                        r_access_op          <= `JWH_OP_SEND_BYTE;
                        r_access_command     <= 8'h15;
                        r_access_write_data  <= 16'd0;
                        r_after_access_state <= ST_STORE_EVAL;
                        r_state              <= ST_ACCESS_REQUEST;
                    end

                    // STORE结果：失败则结束；成功则启动MTP_BUSY轮询计时。
                    ST_STORE_EVAL: begin
                        // 任一PAGE的STORE失败，立即停止后续PAGE，器件保持无效。
                        if (r_last_bus_error) begin
                            o_cfg_resp_error      <= 1'b1;
                            o_cfg_sys_error_code  <= SYS_ERR_BUS;
                            o_cfg_bus_error_code  <= r_last_bus_error_code;
                            o_cfg_error_index     <= r_cfg_index;
                            r_state               <= ST_CFG_RESPONSE;
                        end else begin
                            r_mtp_total_counter   <= 48'd0;
                            r_mtp_poll_counter    <= 48'd0;
                            r_state               <= ST_MTP_POLL_WAIT;
                        end
                    end

                    // MTP轮询间隔：累计总超时，并等待下一次状态读取时刻。
                    ST_MTP_POLL_WAIT: begin
                        // 总超时优先于下一次轮询，避免故障器件无限占用总线。
                        if ((P_MTP_TIMEOUT_MS == 0) ||
                            (r_mtp_total_counter >=
                             (P_MTP_TIMEOUT_MS * CYCLES_PER_MS))) begin
                            o_cfg_resp_error      <= 1'b1;
                            o_cfg_sys_error_code  <= SYS_ERR_MTP_TIMEOUT;
                            o_cfg_error_index     <= r_cfg_index;
                            r_state               <= ST_CFG_RESPONSE;
                        // 到达轮询间隔；参数为0时表示无额外等待，立即读取。
                        end else if ((P_MTP_POLL_INTERVAL_MS == 0) ||
                                     (r_mtp_poll_counter >=
                                      (P_MTP_POLL_INTERVAL_MS *
                                       CYCLES_PER_MS))) begin
                            r_mtp_poll_counter <= 48'd0;
                            r_state            <= ST_MTP_POLL_PREP;
                        end else begin
                            r_mtp_total_counter <= r_mtp_total_counter + 1'b1;
                            r_mtp_poll_counter  <= r_mtp_poll_counter + 1'b1;
                        end
                    end

                    // MTP状态读取：访问Page0的STATUS_MFR_SPECIFIC(71h)。
                    ST_MTP_POLL_PREP: begin
                        r_access_device_id   <= r_cfg_device_id;
                        r_access_page        <= 8'd0;
                        r_access_op          <= `JWH_OP_READ_BYTE;
                        r_access_command     <= 8'h71;
                        r_access_write_data  <= 16'd0;
                        r_after_access_state <= ST_MTP_POLL_EVAL;
                        r_state              <= ST_ACCESS_REQUEST;
                    end

                    // MTP状态判断：BUSY或允许的NACK继续轮询，其余错误退出。
                    ST_MTP_POLL_EVAL: begin
                        if (r_last_bus_error) begin
                            // MTP忙期间地址/命令/数据NACK允许重试。
                            if ((r_last_bus_error_code >=
                                 `JWH_ERR_NACK_ADDR) &&
                                (r_last_bus_error_code <=
                                 `JWH_ERR_NACK_DATA)) begin
                                r_state <= ST_MTP_POLL_WAIT;
                            end else begin
                                // timeout/PEC等非NACK错误不重试，直接上报。
                                o_cfg_resp_error      <= 1'b1;
                                o_cfg_sys_error_code  <= SYS_ERR_BUS;
                                o_cfg_bus_error_code  <= r_last_bus_error_code;
                                o_cfg_error_index     <= r_cfg_index;
                                r_state               <= ST_CFG_RESPONSE;
                            end
                        // MTP_BUSY=1：返回轮询等待；为0：进入当前页CRC读取。
                        end else if (r_last_bus_data[3]) begin
                            r_state <= ST_MTP_POLL_WAIT;
                        end else begin
                            r_state <= ST_MTP_CRC_PREP;
                        end
                    end

                    // MTP CRC读取：访问当前固化PAGE的CRC寄存器F0h。
                    ST_MTP_CRC_PREP: begin
                        r_access_device_id   <= r_cfg_device_id;
                        r_access_page        <= {6'd0, r_store_page};
                        r_access_op          <= `JWH_OP_READ_WORD;
                        r_access_command     <= 8'hF0;
                        r_access_write_data  <= 16'd0;
                        r_after_access_state <= ST_MTP_CRC_EVAL;
                        r_state              <= ST_ACCESS_REQUEST;
                    end

                    // MTP CRC结果：保存CRC；读失败则返回配置错误。
                    ST_MTP_CRC_EVAL: begin
                        // CRC寄存器读失败同样中止三页固化流程。
                        if (r_last_bus_error) begin
                            o_cfg_resp_error      <= 1'b1;
                            o_cfg_sys_error_code  <= SYS_ERR_BUS;
                            o_cfg_bus_error_code  <= r_last_bus_error_code;
                            o_cfg_error_index     <= r_cfg_index;
                            r_state               <= ST_CFG_RESPONSE;
                        end else begin
                            o_cfg_last_mtp_crc <= r_last_bus_data;
                            if (r_store_page < 2'd2) begin
                                // 当前页固化完成：推进到下一PAGE重新STORE。
                                r_store_page <= r_store_page + 1'b1;
                                r_state      <= ST_STORE_PREP;
                            end else begin
                                // Page2 CRC完成，三个PAGE均已成功固化。
                                r_state <= ST_CFG_FINISH;
                            end
                        end
                    end

                    // 配置推进：读取下一条记录，或转入可选STORE/成功收尾。
                    ST_CFG_ADVANCE: begin
                        // RAM还有记录时继续；最后一条后才决定是否固化。
                        if ({1'b0, r_cfg_index} + 11'd1 <
                            r_cfg_record_count) begin
                            r_cfg_index <= r_cfg_index + 1'b1;
                            r_state     <= ST_CFG_RAM_REQUEST;
                        end else if (r_cfg_config_mode &&
                                     r_cfg_store_after) begin
                            // 固化固定从Page0开始，随后由CRC状态推进到1、2。
                            r_store_page <= 2'd0;
                            r_state <= ST_STORE_PREP;
                        end else begin
                            r_state <= ST_CFG_FINISH;
                        end
                    end

                    // 任务成功收尾：遥测通道由上位机位图独立控制。
                    ST_CFG_FINISH: begin
                        r_state <= ST_CFG_RESPONSE;
                    end

                    // 配置响应：保持结果有效，直到上层完成ready/valid握手。
                    ST_CFG_RESPONSE: begin
                        o_cfg_resp_valid <= 1'b1;
                        if (o_cfg_resp_valid && i_cfg_resp_ready) begin
                            o_cfg_resp_valid <= 1'b0;
                            r_state          <= ST_IDLE;
                        end
                    end

                    // 遥测筛选：上位机16位掩码直接控制8设备、2个Rail。
                    ST_MONITOR_CHECK: begin
                        if (!(|i_telemetry_enable)) begin
                            r_state <= ST_IDLE;
                        end else if (i_telemetry_enable[
                            {r_poll_device[2:0], r_poll_rail}]) begin
                            o_current_device_id <= r_poll_device;
                            r_state             <= ST_MONITOR_PREP;
                        end else begin
                            r_state <= ST_MONITOR_ADVANCE;
                        end
                    end

                    // 遥测读取：依次发起STATUS_WORD、READ_VOUT和READ_IOUT。
                    ST_MONITOR_PREP: begin
                        r_access_device_id   <= r_poll_device;
                        r_access_page        <= r_poll_rail ? 8'd1 : 8'd0;
                        r_access_op          <= `JWH_OP_READ_WORD;
                        case (r_poll_item)
                            TEL_STATUS: r_access_command <= 8'h79;
                            TEL_VOUT:   r_access_command <= 8'h8B;
                            default:    r_access_command <= 8'h8C;
                        endcase
                        r_access_write_data  <= 16'd0;
                        r_after_access_state <= ST_MONITOR_STORE;
                        r_state              <= ST_ACCESS_REQUEST;
                    end

                    // 遥测保存：把最新原始值及总线状态写入外部遥测RAM。
                    ST_MONITOR_STORE: begin
                        o_tel_wr_en   <= 1'b1;
                        o_tel_wr_addr <= {r_poll_device, r_poll_rail,
                                          r_poll_item};
                        o_tel_wr_data <= {1'b1, r_last_bus_error, 5'd0,
                                          r_last_bus_error_code, 4'd0,
                                          r_last_bus_data};
                        r_state <= ST_MONITOR_ADVANCE;
                    end

                    // 遥测推进：切换item、Rail和device，随后让出总线仲裁。
                    ST_MONITOR_ADVANCE: begin
                        if (r_poll_item < TEL_IOUT) begin
                            r_poll_item <= r_poll_item + 1'b1;
                        end else begin
                            r_poll_item <= TEL_STATUS;
                            if (!r_poll_rail) begin
                                r_poll_rail <= 1'b1;
                            end else begin
                                r_poll_rail <= 1'b0;
                                if (r_poll_device == 6'd7)
                                    r_poll_device <= 6'd0;
                                else
                                    r_poll_device <= r_poll_device + 1'b1;
                            end
                        end
                        r_state <= ST_IDLE;
                    end

                    // 告警入口：选出一个待处理TCA支路并清空本次扫描结果。
                    ST_ALERT_BEGIN: begin
                        r_alert_channel    <=
                            f_first_alert_channel(r_alert_pending);
                        r_alert_found_mask <= 8'd0;
                        r_state            <= ST_ALERT_PREP;
                    end

                    // ARA请求：TCA选中告警支路后，从地址0x0C读取响应者地址。
                    ST_ALERT_PREP: begin
                        r_access_device_id   <=
                            {r_alert_channel, 3'd0};
                        // ARA不属于任何PAGE，bus controller会按OP_ARA旁路缓存。
                        r_access_page        <= 8'd0;
                        r_access_op          <= `JWH_OP_ARA;
                        r_access_command     <= 8'd0;
                        r_access_write_data  <= 16'd0;
                        r_after_access_state <= ST_ALERT_EVAL;
                        r_state              <= ST_ACCESS_REQUEST;
                    end

                    // ARA结果：记录返回地址；地址NACK表示该支路已无响应者。
                    ST_ALERT_EVAL: begin
                        if (!r_last_bus_error) begin
                            // 返回字节[7:1]是7位PMBus地址，只接受本支路0..7。
                            if ((r_last_bus_data[7:1] >= P_JWH_ADDR_BASE) &&
                                (r_last_bus_data[7:1] <=
                                 P_JWH_ADDR_BASE + 7)) begin
                                r_alert_found_mask[
                                    r_last_bus_data[7:1] -
                                    P_JWH_ADDR_BASE] <= 1'b1;
                            end
                            // 一次ARA只释放一个设备，继续查询其余响应者。
                            r_state <= ST_ALERT_PREP;
                        end else if (r_last_bus_error_code == 5'd1) begin
                            // ARA地址NACK是正常结束标志，不作为业务错误。
                            r_state <= ST_ALERT_ADVANCE;
                        end else begin
                            // timeout/恢复/其他协议错误结束本轮，保留已找到mask。
                            r_state <= ST_ALERT_ADVANCE;
                        end
                    end

                    // 告警推进：ARA循环结束，提交整条支路的8位地址mask。
                    ST_ALERT_ADVANCE: begin
                        o_alert_report_channel     <= r_alert_channel;
                        o_alert_report_device_mask <= r_alert_found_mask;
                        r_state                    <= ST_ALERT_REPORT;
                    end

                    // 告警报告：保持支路号和器件掩码，等待上层接收。
                    ST_ALERT_REPORT: begin
                        o_alert_report_valid <= 1'b1;
                        if (o_alert_report_valid &&
                            i_alert_report_ready) begin
                            o_alert_report_valid <= 1'b0;
                            r_state              <= ST_IDLE;
                        end
                    end

                    default: r_state <= ST_IDLE;
            endcase
        end
    end

    jwh6374_bus_controller #(
        .P_SYS_CLK_FREQ    (P_SYS_CLK_FREQ),
        .P_I2C_BAUD_RATE   (P_I2C_BAUD_RATE),
        .P_I2C_TIMEOUT_MS  (P_I2C_TIMEOUT_MS),
        .P_TCA_ADDR        (P_TCA_ADDR),
        .P_TCA_DEAD_CYCLES (P_TCA_DEAD_CYCLES),
        .P_PEC_ENABLE      (P_PEC_ENABLE),
        .P_TCA_ENABLE      (P_TCA_ENABLE)
    ) u_bus_controller (
        .i_clk                 (i_clk),
        .i_rst_n               (i_rst_n),
        .i_clear               (i_clear),
        .i_req_valid           (r_bus_req_valid),
        .o_req_ready           (w_bus_req_ready),
        .i_req_channel         (r_bus_req_channel),
        .i_req_dev_addr        (r_bus_req_dev_addr),
        .i_req_page            (r_bus_req_page),
        .i_req_op              (r_bus_req_op),
        .i_req_command         (r_bus_req_command),
        .i_req_write_data      (r_bus_req_write_data),
        .o_resp_valid          (w_bus_resp_valid),
        .i_resp_ready          (1'b1),
        .o_resp_read_data      (w_bus_resp_read_data),
        .o_resp_error          (w_bus_resp_error),
        .o_resp_error_code     (w_bus_resp_error_code),
        .o_debug_state                 (o_debug_bus_state),
        .o_debug_tca_enabled           (o_debug_tca_enabled),
        .o_debug_page_cache_valid      (o_debug_page_cache_valid),
        .o_debug_page_cache_page       (o_debug_page_cache_page),
        .o_debug_request_needs_page    (o_debug_request_needs_page),
        .o_debug_active_channel        (o_debug_active_channel),
        .o_debug_active_channel_valid  (o_debug_active_channel_valid),
        .i_scl_i               (i_scl_i),
        .o_scl_o               (o_scl_o),
        .o_scl_t               (o_scl_t),
        .i_sda_i               (i_sda_i),
        .o_sda_o               (o_sda_o),
        .o_sda_t               (o_sda_t)
    );

endmodule
