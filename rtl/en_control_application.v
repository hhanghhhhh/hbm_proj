`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * 模块说明
 *
 * 功能：
 * - 处理 128 路 EN 直接控制、EN 序列 RAM 写入和序列启动命令；三类命令
 *   成功时均返回单字节 STATUS_SUCCESS。
 *
 * 关键数据：
 * - 0x30 Payload 为 16 字节大端 EN_STATE，首字节对应 bit[127:120]；完整
 *   收齐后一次性更新 o_en_state，不暴露部分更新状态。
 * - 0x31 Payload 为 OFFSET(2) | DATA(2*N)，OFFSET 和 DATA 均为大端
 *   16 位 word；N>=1，写入范围不得越过 1024x16 序列 RAM。
 * - 0x32 Payload 为单字节 SEQUENCE_ID，仅低 4 位传给序列控制器。
 *
 * 关键约束：
 * - 序列启动接口没有 ready/完成回传；上层必须保证控制器可接收启动，
 *   本模块的成功响应只表示启动脉冲已经发出。
 *
 * 特殊行为：
 * - i_abort 取消当前命令，但不回滚已更新的 EN 状态或已写入的序列 RAM。
 */
module en_control_application (
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

    output reg  [127:0] o_en_state,
    output reg          o_seq_ram_wr_en,
    output reg  [9:0]   o_seq_ram_wr_addr,
    output reg  [15:0]  o_seq_ram_wr_data,
    output reg  [3:0]   o_sequence_id,
    output reg          o_sequence_start
);

    // Payload RAM 是同步读接口，因此每读取一个字节均经过 WAIT/BYTE 两个状态。
    // WRITE_RSP/RSP_DONE 分别写入响应状态字节和通知响应缓冲区发送。
    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_DIRECT_WAIT  = 4'd1;
    localparam [3:0] ST_DIRECT_BYTE  = 4'd2;
    localparam [3:0] ST_SEQ_WAIT     = 4'd3;
    localparam [3:0] ST_SEQ_BYTE     = 4'd4;
    localparam [3:0] ST_START_WAIT   = 4'd5;
    localparam [3:0] ST_START_BYTE   = 4'd6;
    localparam [3:0] ST_WRITE_RSP    = 4'd7;
    localparam [3:0] ST_RSP_DONE     = 4'd8;

    reg [3:0]   state;
    reg [15:0]  req_length;
    reg [127:0] en_state_shift;
    reg [7:0]   seq_offset_high;
    reg [7:0]   seq_data_high;
    reg [9:0]   seq_write_addr;

    // 直接 EN 控制数据按网络顺序接收，高字节先到；第 16 字节到达时
    // en_state_next 已包含完整 128 bit，可用于一次性更新外部状态。
    wire [127:0] en_state_next;

    // 时序 RAM 的 OFFSET 和 DATA 都以 16-bit word 为单位。
    // 使用 17 bit 计算结束地址，以便识别越过 1024-word RAM 的情况。
    wire [16:0]  seq_word_count;
    wire [16:0]  seq_start_addr;
    wire [16:0]  seq_end_addr;

    assign en_state_next = {en_state_shift[119:0], i_payload_rd_data};
    assign seq_word_count = ({1'b0, req_length} - 17'd2) >> 1;
    assign seq_start_addr = {1'b0, seq_offset_high, i_payload_rd_data};
    assign seq_end_addr   = seq_start_addr + seq_word_count;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state             <= ST_IDLE;
            req_length        <= 16'd0;
            en_state_shift    <= 128'd0;
            seq_offset_high   <= 8'd0;
            seq_data_high     <= 8'd0;
            seq_write_addr    <= 10'd0;
            o_payload_rd_addr <= 11'd0;
            o_rsp_wr_en       <= 1'b0;
            o_rsp_wr_addr     <= 11'd0;
            o_rsp_wr_data     <= 8'd0;
            o_rsp_length      <= 16'd0;
            o_rsp_valid       <= 1'b0;
            o_error_valid     <= 1'b0;
            o_error_code      <= 8'd0;
            o_en_state        <= 128'd0;
            o_seq_ram_wr_en   <= 1'b0;
            o_seq_ram_wr_addr <= 10'd0;
            o_seq_ram_wr_data <= 16'd0;
            o_sequence_id     <= 4'd0;
            o_sequence_start  <= 1'b0;
        end else begin
            // 以下控制信号均为单周期脉冲，各状态仅在需要时将其置位。
            o_rsp_wr_en      <= 1'b0;
            o_rsp_valid      <= 1'b0;
            o_error_valid    <= 1'b0;
            o_seq_ram_wr_en  <= 1'b0;
            o_sequence_start <= 1'b0;

            if (i_abort) begin
                // 上层事务超时后放弃当前命令，已提交的输出状态不回滚。
                state <= ST_IDLE;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (i_req_valid) begin
                            req_length        <= i_req_length;
                            o_payload_rd_addr <= 11'd0;
                            o_rsp_length      <= 16'd1;
                            case (i_req_cmd)
                                `COMM_CMD_DEBUG_EN_WRITE: begin
                                    // 128 路 EN 状态固定占用 16 字节。
                                    if (i_req_length == 16'd16) begin
                                        en_state_shift <= 128'd0;
                                        state <= ST_DIRECT_WAIT;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end

                                `COMM_CMD_EN_SEQUENCE_DATA: begin
                                    // 至少包含 OFFSET 和一个数据 word，长度必须为偶数。
                                    if ((i_req_length >= 16'd4) &&
                                        !i_req_length[0]) begin
                                        state <= ST_SEQ_WAIT;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end

                                `COMM_CMD_EN_SEQUENCE_START: begin
                                    // sequence_id 当前为 4 bit，协议字段保留为一个字节。
                                    if (i_req_length == 16'd1) begin
                                        state <= ST_START_WAIT;
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

                    ST_DIRECT_WAIT: begin
                        // Payload RAM 为同步读，等待当前地址的数据返回。
                        state <= ST_DIRECT_BYTE;
                    end

                    ST_DIRECT_BYTE: begin
                        en_state_shift <= en_state_next;
                        if (o_payload_rd_addr == 11'd15) begin
                            // 完整接收 16 字节后再原子更新，避免输出中间状态。
                            o_en_state <= en_state_next;
                            state      <= ST_WRITE_RSP;
                        end else begin
                            o_payload_rd_addr <= o_payload_rd_addr + 1'b1;
                            state <= ST_DIRECT_WAIT;
                        end
                    end

                    ST_SEQ_WAIT: begin
                        // 等待同步 Payload RAM 返回当前地址的数据。
                        state <= ST_SEQ_BYTE;
                    end

                    ST_SEQ_BYTE: begin
                        if (o_payload_rd_addr == 11'd0) begin
                            // OFFSET[15:8]。
                            seq_offset_high <= i_payload_rd_data;
                            o_payload_rd_addr <= o_payload_rd_addr + 1'b1;
                            state <= ST_SEQ_WAIT;
                        end else if (o_payload_rd_addr == 11'd1) begin
                            // OFFSET 和数据均以 16-bit word 为单位且采用大端。
                            // 同时检查起始地址及整段写入数据不会越过 RAM 末端。
                            if ((seq_offset_high[7:2] != 6'd0) ||
                                (seq_end_addr > 17'd1024)) begin
                                o_error_valid <= 1'b1;
                                o_error_code  <= `COMM_ERROR_PARAM;
                                state         <= ST_IDLE;
                            end else begin
                                seq_write_addr <= {seq_offset_high[1:0], i_payload_rd_data};
                                o_payload_rd_addr <= o_payload_rd_addr + 1'b1;
                                state <= ST_SEQ_WAIT;
                            end
                        end else if (!o_payload_rd_addr[0]) begin
                            // 每个 16-bit 数据 word 的高字节。
                            seq_data_high <= i_payload_rd_data;
                            o_payload_rd_addr <= o_payload_rd_addr + 1'b1;
                            state <= ST_SEQ_WAIT;
                        end else begin
                            // 收到低字节后拼成一个 word，并连续递增 RAM 地址。
                            o_seq_ram_wr_en   <= 1'b1;
                            o_seq_ram_wr_addr <= seq_write_addr;
                            o_seq_ram_wr_data <= {seq_data_high, i_payload_rd_data};
                            seq_write_addr <= seq_write_addr + 1'b1;
                            if (o_payload_rd_addr == req_length - 1'b1) begin
                                state <= ST_WRITE_RSP;
                            end else begin
                                o_payload_rd_addr <= o_payload_rd_addr + 1'b1;
                                state <= ST_SEQ_WAIT;
                            end
                        end
                    end

                    ST_START_WAIT: begin
                        state <= ST_START_BYTE;
                    end

                    ST_START_BYTE: begin
                        // 参数先锁存，再向序列控制器发出单周期启动脉冲。
                        o_sequence_id    <= i_payload_rd_data[3:0];
                        o_sequence_start <= 1'b1;
                        state            <= ST_WRITE_RSP;
                    end

                    ST_WRITE_RSP: begin
                        // 三类控制命令成功时均回复一个 STATUS 字节。
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= 11'd0;
                        o_rsp_wr_data <= `COMM_STATUS_SUCCESS;
                        state         <= ST_RSP_DONE;
                    end

                    ST_RSP_DONE: begin
                        o_rsp_valid <= 1'b1;
                        state       <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
