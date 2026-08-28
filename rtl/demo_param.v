`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * 参数类 demo：读写一个 32 位内部测试寄存器。
 *
 * CMD 0x10：请求 LENGTH=0；响应为 STATUS=0，加四字节大端寄存器值。
 * CMD 0x11：请求 LENGTH=4，Payload 为四字节大端值；响应只有 STATUS=0。
 * 本类别的其他子命令、错误长度通过 error_valid/error_code 提交给
 * 外部 Error Response Generator，本模块不生成错误响应 Payload。
 *
 * 请求公共字段由 Dispatcher 提供，仅在 i_req_valid 时采样。
 * i_req_seq 保留统一请求接口，响应帧的 CMD/SEQ 由外部发送链路沿用，
 * 本模块不修改响应上下文，也不等待串口发送结束。
 * Payload 读地址经 Dispatcher 连接到 Parser 的 1clk 同步读 RAM；
 * 响应写接口经 Response Buffer 连接 TX Frame Builder 的 RAM。
 * 完成全部响应写入后产生单周期 o_rsp_valid。
 *
 * 单事务约束由上层保证，不提供 ready、排队或重复请求检测。
 * i_abort 中止未完成的处理，不回滚已经完整写入的测试寄存器。
 * 全部四字节收齐后才更新 o_demo_param，防止中途 abort 提交部分值。
 * i_rst_n 为异步低有效复位。
 */
module demo_param (
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

    output reg  [31:0] o_demo_param
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_READ_WAIT = 3'd1;
    localparam [2:0] ST_READ_BYTE = 3'd2;
    localparam [2:0] ST_RSP_WRITE = 3'd3;
    localparam [2:0] ST_RSP_DONE  = 3'd4;

    reg [2:0]  state;
    reg [31:0] write_value;
    reg [31:0] read_value;
    reg [2:0]  rsp_index;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state             <= ST_IDLE;
            write_value       <= 32'd0;
            read_value        <= 32'd0;
            rsp_index         <= 3'd0;
            o_demo_param      <= 32'd0;
            o_payload_rd_addr <= 11'd0;
            o_rsp_wr_en       <= 1'b0;
            o_rsp_wr_addr     <= 11'd0;
            o_rsp_wr_data     <= 8'd0;
            o_rsp_length      <= 16'd0;
            o_rsp_valid       <= 1'b0;
            o_error_valid     <= 1'b0;
            o_error_code      <= 8'd0;
        end else begin
            o_rsp_wr_en   <= 1'b0;
            o_rsp_valid   <= 1'b0;
            o_error_valid <= 1'b0;

            if (i_abort) begin
                state <= ST_IDLE;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (i_req_valid) begin
                            rsp_index <= 3'd0;
                            case (i_req_cmd)
                                `COMM_CMD_PARAM_READ: begin
                                    if (i_req_length == 16'd0) begin
                                        /* 对读请求保存当前值，响应按大端顺序返回。 */
                                        read_value   <= o_demo_param;
                                        o_rsp_length <= 16'd5;
                                        state        <= ST_RSP_WRITE;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end
                                `COMM_CMD_PARAM_WRITE: begin
                                    if (i_req_length == 16'd4) begin
                                        write_value       <= 32'd0;
                                        o_payload_rd_addr <= 11'd0;
                                        o_rsp_length      <= 16'd1;
                                        state             <= ST_READ_WAIT;
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
                        /* 地址已输出，本周期等待同步 RAM 更新读数据。 */
                        state <= ST_READ_BYTE;
                    end

                    ST_READ_BYTE: begin
                        write_value <= {write_value[23:0], i_payload_rd_data};
                        if (o_payload_rd_addr == 11'd3) begin
                            o_demo_param <= {write_value[23:0], i_payload_rd_data};
                            state        <= ST_RSP_WRITE;
                        end else begin
                            o_payload_rd_addr <= o_payload_rd_addr + 1'b1;
                            state             <= ST_READ_WAIT;
                        end
                    end

                    ST_RSP_WRITE: begin
                        /* 写接口无反压，每个 wr_en 周期向响应 RAM 提交一个字节。 */
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= {8'd0, rsp_index};
                        case (rsp_index)
                            3'd0:    o_rsp_wr_data <= `COMM_STATUS_SUCCESS;
                            3'd1:    o_rsp_wr_data <= read_value[31:24];
                            3'd2:    o_rsp_wr_data <= read_value[23:16];
                            3'd3:    o_rsp_wr_data <= read_value[15:8];
                            default: o_rsp_wr_data <= read_value[7:0];
                        endcase
                        if ((o_rsp_length == 16'd1) || (rsp_index == 3'd4)) begin
                            state <= ST_RSP_DONE;
                        end else begin
                            rsp_index <= rsp_index + 1'b1;
                        end
                    end

                    ST_RSP_DONE: begin
                        /* 最后一个写脉冲在本时钟沿被 RAM 接收，随后提交响应。 */
                        o_rsp_valid <= 1'b1;
                        state       <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
