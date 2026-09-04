`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * 模块说明
 *
 * 功能：
 * - 处理 128 通道遥测使能位图更新和按位图选择的遥测回读；本模块只读取
 *   外部遥测 RAM，不负责采集或冻结数据。
 *
 * 关键数据：
 * - ENABLE 和 READ Payload 均为 16 字节大端位图，首字节对应 bit[127:120]；
 *   bit[n] 映射为 BUS=n[6:4]、DEVICE_ID=n[3:1]、RAIL=n[0]。
 * - ENABLE 位图完整收齐后一次性更新，避免出现部分新配置。
 * - READ 按通道号 0..127 返回置位通道，
 *   每通道为 VOLTAGE(2) | CURRENT(2) | STATUS(2)，
 *   各字段均取 RAM 低 16 位并按大端输出。
 * - 选择全部 128 个通道时，响应 Payload 长度为 1 + 128×6 = 769 字节。
 *
 * 关键约束：
 * - 回读期间不会冻结后台遥测；同一响应中的不同通道或不同项目可能来自
 *   不同采样时刻，使用方不得将其视为原子快照。
 *
 * 特殊行为：
 * - i_abort 可取消正在解析或回读的请求，但不回滚已完整提交的使能位图，
 *   也不清除已写入外部响应 RAM 的字节。
 */
module telemetry_application (
    input  wire         i_clk,
    input  wire         i_rst_n,
    input  wire         i_abort,
    input  wire         i_req_valid,
    input  wire [7:0]   i_req_cmd,
    input  wire [7:0]   i_req_seq,
    input  wire [15:0]  i_req_length,

    output reg  [10:0]  o_payload_rd_addr,
    input  wire [7:0]   i_payload_rd_data,

    output reg          o_rsp_wr_en,
    output reg  [10:0]  o_rsp_wr_addr,
    output reg  [7:0]   o_rsp_wr_data,
    output reg  [15:0]  o_rsp_length,
    output reg          o_rsp_valid,
    output reg          o_error_valid,
    output reg  [7:0]   o_error_code,

    output reg  [127:0] o_telemetry_enable,

    output reg          o_tel_rd_en,
    output reg  [2:0]   o_tel_rd_bus,
    output reg  [8:0]   o_tel_rd_addr,
    input  wire [31:0]  i_tel_rd_data
);

    localparam [3:0] ST_IDLE          = 4'd0;
    localparam [3:0] ST_READ_WAIT     = 4'd1;
    localparam [3:0] ST_READ_BYTE     = 4'd2;
    localparam [3:0] ST_ENABLE_RSP    = 4'd3;
    localparam [3:0] ST_READ_STATUS   = 4'd4;
    localparam [3:0] ST_FIND_CHANNEL  = 4'd5;
    localparam [3:0] ST_TEL_RAM_REQ   = 4'd6;
    localparam [3:0] ST_TEL_RAM_WAIT  = 4'd7;
    localparam [3:0] ST_TEL_CAPTURE   = 4'd8;
    localparam [3:0] ST_CHANNEL_WRITE = 4'd9;
    localparam [3:0] ST_RSP_DONE      = 4'd10;

    localparam [1:0] TEL_VOLTAGE = 2'd0;
    localparam [1:0] TEL_CURRENT = 2'd1;
    localparam [1:0] TEL_STATUS  = 2'd2;

    reg [3:0]   state;
    reg [7:0]   req_cmd;
    reg [127:0] request_mask;
    reg [127:0] read_mask;
    reg [6:0]   channel_index;
    reg [1:0]   tel_item;
    reg [15:0]  voltage_data;
    reg [15:0]  current_data;
    reg [15:0]  status_data;
    reg [2:0]   channel_byte_index;
    reg [10:0]  rsp_write_addr;
    reg [7:0]   selected_channel_count;

    wire [127:0] request_mask_next;

    assign request_mask_next = {request_mask[119:0], i_payload_rd_data};

    function [3:0] f_count_byte;
        input [7:0] mask_byte;
        integer bit_index;
        begin
            f_count_byte = 4'd0;
            for (bit_index = 0; bit_index < 8;
                 bit_index = bit_index + 1) begin
                f_count_byte = f_count_byte + mask_byte[bit_index];
            end
        end
    endfunction

    function [1:0] f_ram_item;
        input [1:0] item;
        begin
            case (item)
                TEL_VOLTAGE: f_ram_item = 2'd1;
                TEL_CURRENT: f_ram_item = 2'd2;
                default:     f_ram_item = 2'd0;
            endcase
        end
    endfunction

    // 包含当前最后一个位图字节的通道总数，扩展为 16 位后再参与移位。
    wire [15:0] selected_channel_count_with_current;
    assign selected_channel_count_with_current =
        {8'd0, selected_channel_count} +
        {12'd0, f_count_byte(i_payload_rd_data)};

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state                <= ST_IDLE;
            req_cmd              <= 8'd0;
            request_mask         <= 128'd0;
            read_mask            <= 128'd0;
            channel_index        <= 7'd0;
            tel_item             <= TEL_VOLTAGE;
            voltage_data         <= 16'd0;
            current_data         <= 16'd0;
            status_data          <= 16'd0;
            channel_byte_index   <= 3'd0;
            rsp_write_addr       <= 11'd1;
            selected_channel_count <= 8'd0;
            o_payload_rd_addr    <= 11'd0;
            o_rsp_wr_en          <= 1'b0;
            o_rsp_wr_addr        <= 11'd0;
            o_rsp_wr_data        <= 8'd0;
            o_rsp_length         <= 16'd0;
            o_rsp_valid          <= 1'b0;
            o_error_valid        <= 1'b0;
            o_error_code         <= 8'd0;
            o_telemetry_enable   <= 128'd0;
            o_tel_rd_en          <= 1'b0;
            o_tel_rd_bus         <= 3'd0;
            o_tel_rd_addr        <= 9'd0;
        end else begin
            o_rsp_wr_en   <= 1'b0;
            o_rsp_valid   <= 1'b0;
            o_error_valid <= 1'b0;
            o_tel_rd_en   <= 1'b0;

            if (i_abort) begin
                state <= ST_IDLE;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (i_req_valid) begin
                            req_cmd           <= i_req_cmd;
                            request_mask      <= 128'd0;
                            selected_channel_count <= 8'd0;
                            o_payload_rd_addr <= 11'd0;
                            if ((i_req_cmd ==
                                 `COMM_CMD_TELEMETRY_ENABLE) ||
                                (i_req_cmd ==
                                 `COMM_CMD_TELEMETRY_READ)) begin
                                if (i_req_length == 16'd16) begin
                                    state <= ST_READ_WAIT;
                                end else begin
                                    o_error_valid <= 1'b1;
                                    o_error_code  <=
                                        `COMM_ERROR_LENGTH;
                                end
                            end else begin
                                o_error_valid <= 1'b1;
                                o_error_code  <=
                                    `COMM_ERROR_UNKNOWN_CMD;
                            end
                        end
                    end

                    ST_READ_WAIT: begin
                        // 地址已输出，本周期等待 Parser 同步 RAM 返回数据。
                        state <= ST_READ_BYTE;
                    end

                    ST_READ_BYTE: begin
                        request_mask <= request_mask_next;
                        if (req_cmd == `COMM_CMD_TELEMETRY_READ)
                            selected_channel_count <=
                                selected_channel_count +
                                f_count_byte(i_payload_rd_data);
                        if (o_payload_rd_addr == 11'd15) begin
                            if (req_cmd == `COMM_CMD_TELEMETRY_ENABLE) begin
                                // 全部位图收齐后一次提交，避免出现部分新配置。
                                o_telemetry_enable <= request_mask_next;
                                o_rsp_length       <= 16'd1;
                                state              <= ST_ENABLE_RSP;
                            end else begin
                                read_mask          <= request_mask_next;
                                channel_index      <= 7'd0;
                                rsp_write_addr     <= 11'd1;
                                // 每通道 6 字节等于 4+2，使用移位加法避免推断 DSP。
                                o_rsp_length <=
                                    16'd1 +
                                    (selected_channel_count_with_current << 2) +
                                    (selected_channel_count_with_current << 1);
                                state <= ST_READ_STATUS;
                            end
                        end else begin
                            o_payload_rd_addr <= o_payload_rd_addr + 1'b1;
                            state             <= ST_READ_WAIT;
                        end
                    end

                    ST_ENABLE_RSP: begin
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= 11'd0;
                        o_rsp_wr_data <= `COMM_STATUS_SUCCESS;
                        state         <= ST_RSP_DONE;
                    end

                    ST_READ_STATUS: begin
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= 11'd0;
                        o_rsp_wr_data <= `COMM_STATUS_SUCCESS;
                        state         <= ST_FIND_CHANNEL;
                    end

                    ST_FIND_CHANNEL: begin
                        if (read_mask[channel_index]) begin
                            // 全局通道映射为 BUS、DEVICE_ID 和 RAIL。
                            o_tel_rd_bus  <= channel_index[6:4];
                            o_tel_rd_addr <= {
                                3'd0,
                                channel_index[3:1],
                                channel_index[0],
                                f_ram_item(TEL_VOLTAGE)
                            };
                            tel_item <= TEL_VOLTAGE;
                            state    <= ST_TEL_RAM_REQ;
                        end else if (channel_index == 7'd127) begin
                            state <= ST_RSP_DONE;
                        end else begin
                            channel_index <= channel_index + 1'b1;
                        end
                    end

                    ST_TEL_RAM_REQ: begin
                        o_tel_rd_en <= 1'b1;
                        state       <= ST_TEL_RAM_WAIT;
                    end

                    ST_TEL_RAM_WAIT: begin
                        // RAM 在本时钟沿接收读请求，下一状态再采样返回值。
                        state <= ST_TEL_CAPTURE;
                    end

                    ST_TEL_CAPTURE: begin
                        case (tel_item)
                            TEL_VOLTAGE: begin
                                voltage_data        <= i_tel_rd_data[15:0];
                                tel_item            <= TEL_CURRENT;
                                o_tel_rd_addr[1:0]  <= f_ram_item(TEL_CURRENT);
                                state <= ST_TEL_RAM_REQ;
                            end
                            TEL_CURRENT: begin
                                current_data        <= i_tel_rd_data[15:0];
                                tel_item            <= TEL_STATUS;
                                o_tel_rd_addr[1:0]  <= f_ram_item(TEL_STATUS);
                                state <= ST_TEL_RAM_REQ;
                            end
                            default: begin
                                status_data        <= i_tel_rd_data[15:0];
                                channel_byte_index <= 3'd0;
                                state              <= ST_CHANNEL_WRITE;
                            end
                        endcase
                    end

                    ST_CHANNEL_WRITE: begin
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= rsp_write_addr;
                        case (channel_byte_index)
                            3'd0: o_rsp_wr_data <= voltage_data[15:8];
                            3'd1: o_rsp_wr_data <= voltage_data[7:0];
                            3'd2: o_rsp_wr_data <= current_data[15:8];
                            3'd3: o_rsp_wr_data <= current_data[7:0];
                            3'd4: o_rsp_wr_data <= status_data[15:8];
                            default: o_rsp_wr_data <= status_data[7:0];
                        endcase

                        if (channel_byte_index == 3'd5) begin
                            if (channel_index == 7'd127) begin
                                state <= ST_RSP_DONE;
                            end else begin
                                channel_index  <= channel_index + 1'b1;
                                // 当前低字节已占用本地址，下一通道紧接后一地址。
                                rsp_write_addr <= rsp_write_addr + 1'b1;
                                state          <= ST_FIND_CHANNEL;
                            end
                        end else begin
                            channel_byte_index <= channel_byte_index + 1'b1;
                            rsp_write_addr     <= rsp_write_addr + 1'b1;
                        end
                    end

                    ST_RSP_DONE: begin
                        // 最后一个写脉冲在本时钟沿被响应 RAM 接收。
                        o_rsp_valid <= 1'b1;
                        state       <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
