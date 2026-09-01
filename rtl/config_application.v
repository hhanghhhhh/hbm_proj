`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * Module Contract
 *
 * 模块职责：
 * - 解析配置类请求，为一条选定总线写配置记录、提交配置任务、查询状态或读取结果。
 * - 驱动外部配置 RAM、service 启动握手和结果 RAM 读接口，并生成正常/错误响应事件。
 * - 不负责：例化 RAM/service、解释 32 位配置记录、转换设备地址或取消已接收的后台任务。
 *
 * 输入事务：
 * - 空闲时 i_req_valid=1 开始事务；处理期间忽略新请求，Payload RAM 读延迟按 1clk 处理。
 * - CONFIG_DATA：BUS(1)|OFFSET(2)|DATA(4*N)，N>=1；OFFSET 和记录均为大端。
 * - CONFIG_START：BUS(1)|I2C_ADDR(1)|CONFIG_LENGTH(2)|STORE_FLASH(1)|CONFIG_MODE(1)。
 * - CONFIG_STATUS：LENGTH=0；CONFIG_RESULT_READ：BUS(1)|OFFSET(2)|LENGTH(2)。
 * - BUS 必须小于 BUS_COUNT；未知命令、字段长度或范围非法时提交公共错误事件。
 *
 * 输出事务：
 * - CONFIG_DATA 将每四个数据字节组为一条 32 位记录，从 OFFSET 起连续写外部 RAM。
 * - CONFIG_START 收齐参数后保持 o_cfg_start 及参数稳定，直到 o_cfg_start&&i_cfg_ready 握手。
 * - DATA/START 成功返回单字节 STATUS_SUCCESS；STATUS 返回 STATUS_SUCCESS 和 i_cfg_ok 快照。
 * - RESULT_READ 返回 STATUS_SUCCESS，随后按地址递增返回指定数量的 16 位大端结果。
 * - 正常响应写完后产生 1clk o_rsp_valid；错误产生 1clk o_error_valid 且不提交正常响应。
 *
 * 关键时序：
 * - o_cfg_ram_wr_en、o_cfg_result_rd_en、o_rsp_wr_en 均为 1clk pulse，接口均无反压。
 * - 结果 RAM 读请求保持一拍，并再等待一拍后采样 i_cfg_result_rd_data。
 * - o_cfg_start 是可等待 ready 的电平，不是单周期 pulse；abort 同拍会组合屏蔽该信号。
 * - 最后一个响应写脉冲被外部 RAM 接收后，下一阶段才产生 o_rsp_valid。
 *
 * 异常与恢复：
 * - reset：异步低有效，回到空闲，清除事件、启动请求和输出参数。
 * - abort：取消未完成的解析、结果读取或尚未握手的启动请求，不产生完成事件。
 * - abort 不回滚已写配置记录/响应字节，也不取消此前已被 service 接收的任务。
 *
 * 使用约束：
 * - BUS_COUNT 限定为 1..8；配置和结果 RAM 均按 1024 项容量使用。
 * - CONFIG_DATA 不得越过记录 RAM 末尾；RESULT_READ 数量为 1..1023 且范围不得越界。
 * - 上层必须保证单事务，service 执行期间不覆盖其配置 RAM，并避免读取正在写的结果。
 * - I2C_ADDR 仅使用低 6 位，CONFIG_LENGTH 仅使用低 11 位，两个标志仅使用 bit0。
 *
 * 参考：
 * - CMD_DEFINITION.md：配置类命令、Payload 与错误码定义。
 * - DUT_POWER_CONTROL_FLOW.md：配置任务与后台 service 的系统级时序。
 */
module config_application #(
    parameter integer BUS_COUNT = 8
) (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_abort,
    input  wire        i_req_valid,
    input  wire [7:0]  i_req_cmd,
    input  wire [7:0]  i_req_seq,
    input  wire [15:0] i_req_length,

    output reg  [10:0] o_payload_rd_addr,
    input  wire [7:0]  i_payload_rd_data,

    output reg         o_rsp_wr_en,
    output reg  [10:0] o_rsp_wr_addr,
    output reg  [7:0]  o_rsp_wr_data,
    output reg  [15:0] o_rsp_length,
    output reg         o_rsp_valid,
    output reg         o_error_valid,
    output reg  [7:0]  o_error_code,

    // 数据广播，外部仅将动作使能送给 o_bus_sel 指定的单总线单元。
    output reg  [2:0]  o_bus_sel,
    output reg         o_cfg_ram_wr_en,
    output reg  [9:0]  o_cfg_ram_wr_addr,
    output reg  [31:0] o_cfg_ram_wr_data,

    // start 是待接收请求电平；在 start && ready 的时钟沿接收一次。
    output wire        o_cfg_start,
    input  wire        i_cfg_ready,
    output reg  [5:0]  o_cfg_device_id,
    output reg  [10:0] o_cfg_record_count,
    output reg         o_cfg_store_after,
    output reg         o_cfg_config_mode,
    // 选中总线的结果 RAM 同步读接口，RAM 数据宽度为 16 bit。
    output reg         o_cfg_result_rd_en,
    output reg  [9:0]  o_cfg_result_rd_addr,
    input  wire [15:0] i_cfg_result_rd_data,

    // 八条 I2C 总线的汇总状态，bit[n]=1 表示 BUSn 正常。
    input  wire [7:0]  i_cfg_ok
);

    localparam [3:0] ST_IDLE           = 4'd0;
    localparam [3:0] ST_READ_WAIT      = 4'd1;
    localparam [3:0] ST_READ_BYTE      = 4'd2;
    localparam [3:0] ST_START_WAIT     = 4'd3;
    localparam [3:0] ST_RSP_FIXED_WRITE = 4'd4;
    localparam [3:0] ST_RSP_DONE       = 4'd5;
    localparam [3:0] ST_RESULT_STATUS_WRITE = 4'd7;
    localparam [3:0] ST_RESULT_RAM_REQ = 4'd8;
    localparam [3:0] ST_RESULT_RAM_WAIT = 4'd9;
    localparam [3:0] ST_RESULT_DATA_H  = 4'd10;
    localparam [3:0] ST_RESULT_DATA_L  = 4'd11;

    reg [3:0]  state;
    reg [7:0]  req_cmd;
    reg [15:0] req_length;
    reg [7:0]  offset_high;
    reg [9:0]  ram_write_addr;
    reg [1:0]  data_byte_index;
    reg [39:0] request_value;
    reg [7:0]  cfg_ok_snapshot;
    reg [2:0]  rsp_index;
    reg        cfg_start_pending;
    reg [9:0]  result_words_remaining;
    reg [10:0] result_rsp_wr_addr;

    wire [15:0] data_offset;
    wire [16:0] data_record_count;
    wire [16:0] data_end_record;
    wire [39:0] request_next;

    assign data_offset = {offset_high, i_payload_rd_data};
    // DATA 长度为请求长度减去 BUS 和 OFFSET，再换算为 32 位记录数量。
    assign data_record_count =
        ({1'b0, req_length} - 17'd3) >> 2;
    // 使用扩展位计算末尾记录的后一地址，避免加法溢出后绕回 RAM 起点。
    assign data_end_record = {1'b0, data_offset} + data_record_count;
    assign request_next = {request_value[31:0], i_payload_rd_data};
    // abort 同拍屏蔽尚未握手的启动请求，已接收的 I2C 任务不受影响。
    assign o_cfg_start = cfg_start_pending && !i_abort;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state               <= ST_IDLE;
            req_cmd             <= 8'd0;
            req_length          <= 16'd0;
            offset_high         <= 8'd0;
            ram_write_addr      <= 10'd0;
            data_byte_index     <= 2'd0;
            request_value       <= 40'd0;
            cfg_ok_snapshot     <= 8'd0;
            rsp_index           <= 3'd0;
            cfg_start_pending   <= 1'b0;
            o_payload_rd_addr   <= 11'd0;
            o_rsp_wr_en         <= 1'b0;
            o_rsp_wr_addr       <= 11'd0;
            o_rsp_wr_data       <= 8'd0;
            o_rsp_length        <= 16'd0;
            o_rsp_valid         <= 1'b0;
            o_error_valid       <= 1'b0;
            o_error_code        <= 8'd0;
            o_bus_sel           <= 3'd0;
            o_cfg_ram_wr_en     <= 1'b0;
            o_cfg_ram_wr_addr   <= 10'd0;
            o_cfg_ram_wr_data   <= 32'd0;
            o_cfg_device_id     <= 6'd0;
            o_cfg_record_count  <= 11'd0;
            o_cfg_store_after   <= 1'b0;
            o_cfg_config_mode   <= 1'b0;
            o_cfg_result_rd_en  <= 1'b0;
            o_cfg_result_rd_addr <= 10'd0;
            result_words_remaining <= 10'd0;
            result_rsp_wr_addr  <= 11'd1;
        end else begin
            o_rsp_wr_en     <= 1'b0;
            o_rsp_valid     <= 1'b0;
            o_error_valid   <= 1'b0;
            o_cfg_ram_wr_en <= 1'b0;
            o_cfg_result_rd_en <= 1'b0;

            if (i_abort) begin
                state             <= ST_IDLE;
                cfg_start_pending <= 1'b0;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (i_req_valid) begin
                            req_cmd           <= i_req_cmd;
                            req_length        <= i_req_length;
                            o_payload_rd_addr <= 11'd0;
                            request_value     <= 40'd0;
                            data_byte_index   <= 2'd0;
                            rsp_index         <= 3'd0;
                            o_rsp_length      <= 16'd1;
                            case (i_req_cmd)
                                `COMM_CMD_CONFIG_DATA: begin
                                    // BUS 和两字节偏移后至少包含一条完整记录。
                                    if ((i_req_length >= 16'd7) &&
                                        (i_req_length[1:0] == 2'd3)) begin
                                        state <= ST_READ_WAIT;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end
                                `COMM_CMD_CONFIG_START: begin
                                    if (i_req_length == 16'd6) begin
                                        state <= ST_READ_WAIT;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end
                                `COMM_CMD_CONFIG_STATUS: begin
                                    if (i_req_length == 16'd0) begin
                                        cfg_ok_snapshot <= i_cfg_ok;
                                        o_rsp_length    <= 16'd2;
                                        state           <= ST_RSP_FIXED_WRITE;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end
                                `COMM_CMD_CONFIG_RESULT_READ: begin
                                    if (i_req_length == 16'd5) begin
                                        state <= ST_READ_WAIT;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end
                                default: begin
                                    o_error_valid <= 1'b1;
                                    o_error_code  <= `COMM_ERROR_UNKNOWN_CMD;
                                end
                            endcase
                        end
                    end

                    ST_READ_WAIT: begin
                        // 地址已输出，留一拍给 Parser 的同步读 RAM。
                        state <= ST_READ_BYTE;
                    end

                    ST_READ_BYTE: begin
                        request_value <= request_next;
                        // 默认推进读地址，最后一个字节转入应答或启动握手。
                        if ({5'd0, o_payload_rd_addr} == req_length - 16'd1) begin
                            state <= ST_RSP_FIXED_WRITE;
                        end else begin
                            o_payload_rd_addr <= o_payload_rd_addr + 1'b1;
                            state             <= ST_READ_WAIT;
                        end

                        if (o_payload_rd_addr == 11'd0) begin
                            // 先检查完整 BUS 字节，再截取低三位，禁止错误编号绕回。
                            if (i_payload_rd_data >= BUS_COUNT) begin
                                o_error_valid <= 1'b1;
                                o_error_code  <= `COMM_ERROR_PARAM;
                                state         <= ST_IDLE;
                            end else begin
                                o_bus_sel <= i_payload_rd_data[2:0];
                            end
                        end else begin
                            case (req_cmd)
                                `COMM_CMD_CONFIG_DATA: begin
                                    if (o_payload_rd_addr == 11'd1) begin
                                        offset_high <= i_payload_rd_data;
                                    end else if (o_payload_rd_addr == 11'd2) begin
                                        // OFFSET 是记录索引，整包不可越过 1024 条 RAM。
                                        if (data_end_record > 17'd1024) begin
                                            o_error_valid <= 1'b1;
                                            o_error_code  <= `COMM_ERROR_PARAM;
                                            state         <= ST_IDLE;
                                        end else begin
                                            ram_write_addr <= data_offset[9:0];
                                        end
                                    end else begin
                                        data_byte_index <= data_byte_index + 1'b1;
                                        if (data_byte_index == 2'd3) begin
                                            // 收齐四字节再写，第一字节对应 RAM[31:24]。
                                            o_cfg_ram_wr_en   <= 1'b1;
                                            o_cfg_ram_wr_addr <= ram_write_addr;
                                            o_cfg_ram_wr_data <= request_next[31:0];
                                            ram_write_addr    <= ram_write_addr + 1'b1;
                                        end
                                    end
                                end

                                `COMM_CMD_CONFIG_START: begin
                                    if (o_payload_rd_addr == 11'd1) begin
                                        // i2c_addr
                                        o_cfg_device_id    <= request_next[5:0];
                                    end else if (o_payload_rd_addr == 11'd3) begin
                                        // length
                                        o_cfg_record_count <= request_next[10:0];
                                    end else if (o_payload_rd_addr == 11'd4) begin
                                        // store
                                        o_cfg_store_after  <= request_next[0];
                                    end else if (o_payload_rd_addr == 11'd5) begin
                                        // mode
                                        o_cfg_config_mode  <= request_next[0];
                                        // 最后一个字节
                                        if ((o_cfg_device_id > 6'd7) ||
                                            (o_cfg_record_count > 11'd1024)) begin
                                            o_error_valid <= 1'b1;
                                            o_error_code  <= `COMM_ERROR_PARAM;
                                            state         <= ST_IDLE;
                                        end else begin
                                            // 收齐参数整体提交。
                                            cfg_start_pending  <= 1'b1;
                                            state              <= ST_START_WAIT;
                                        end
                                    end
                                end
                                `COMM_CMD_CONFIG_RESULT_READ: begin
                                    if (o_payload_rd_addr == 11'd4) begin
                                        // 请求字段：BUS | OFFSET[15:0] | LENGTH[15:0]。
                                        if ((request_next[15:0] == 16'd0) ||
                                            (request_next[15:0] > 16'd1023) ||
                                            ({1'b0, request_next[31:16]} +
                                             {1'b0, request_next[15:0]} >
                                             17'd1024)) begin
                                            o_error_valid <= 1'b1;
                                            o_error_code  <= `COMM_ERROR_PARAM;
                                            state         <= ST_IDLE;
                                        end else begin
                                            o_cfg_result_rd_addr <=
                                                request_next[25:16];
                                            result_words_remaining <=
                                                request_next[9:0];
                                            result_rsp_wr_addr <= 11'd1;
                                            o_rsp_length <=
                                                16'd1 +
                                                {request_next[14:0], 1'b0};
                                            state <= ST_RESULT_STATUS_WRITE;
                                        end
                                    end
                                end
                                default: state <= ST_IDLE;
                            endcase
                        end
                    end

                    ST_START_WAIT: begin
                        // 参数保持稳定，允许后台遥测让出总线后再接收启动。
                        if (o_cfg_start && i_cfg_ready) begin
                            cfg_start_pending <= 1'b0;
                            state             <= ST_RSP_FIXED_WRITE;
                        end
                    end

                    ST_RSP_FIXED_WRITE: begin
                        // 固定短响应：单字节成功，或 STATUS 加 32 位状态。
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= {8'd0, rsp_index};
                        case (rsp_index)
                            3'd0:    o_rsp_wr_data <= `COMM_STATUS_SUCCESS;
                            default: o_rsp_wr_data <= cfg_ok_snapshot;
                        endcase
                        if ((o_rsp_length == 16'd1) || (rsp_index == 3'd1)) begin
                            state <= ST_RSP_DONE;
                        end else begin
                            rsp_index <= rsp_index + 1'b1;
                        end
                    end

                    ST_RESULT_STATUS_WRITE: begin
                        // 变长结果响应先写 STATUS，数据从响应地址 1 开始。
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= 11'd0;
                        o_rsp_wr_data <= `COMM_STATUS_SUCCESS;
                        state         <= ST_RESULT_RAM_REQ;
                    end

                    ST_RESULT_RAM_REQ: begin
                        // 读使能保持一个周期，地址在整个请求周期内稳定。
                        o_cfg_result_rd_en <= 1'b1;
                        state              <= ST_RESULT_RAM_WAIT;
                    end

                    ST_RESULT_RAM_WAIT: begin
                        // RAM 在本时钟沿接收读请求，下一状态再使用返回值。
                        state <= ST_RESULT_DATA_H;
                    end

                    ST_RESULT_DATA_H: begin
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= result_rsp_wr_addr;
                        o_rsp_wr_data <= i_cfg_result_rd_data[15:8];
                        state         <= ST_RESULT_DATA_L;
                    end

                    ST_RESULT_DATA_L: begin
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= result_rsp_wr_addr + 1'b1;
                        o_rsp_wr_data <= i_cfg_result_rd_data[7:0];
                        if (result_words_remaining == 10'd1) begin
                            state <= ST_RSP_DONE;
                        end else begin
                            result_words_remaining <=
                                result_words_remaining - 1'b1;
                            o_cfg_result_rd_addr <=
                                o_cfg_result_rd_addr + 1'b1;
                            result_rsp_wr_addr <= result_rsp_wr_addr + 2'd2;
                            state <= ST_RESULT_RAM_REQ;
                        end
                    end

                    ST_RSP_DONE: begin
                        // 最后一个响应字节已被 RAM 接收，再通知外部开始组帧。
                        o_rsp_valid <= 1'b1;
                        state       <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
