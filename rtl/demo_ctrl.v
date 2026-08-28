`timescale 1ns / 1ps
`include "cmd_dispatcher_defs.vh"

/*
 * 控制类 demo：设置、查询一个内部测试使能标志，不驱动实际硬件输出。
 *
 * CMD 0x20：请求 LENGTH=0；响应为 STATUS=0，再加一字节当前使能值。
 * CMD 0x21：请求 LENGTH=1，Payload 为 0 或 1；响应只有 STATUS=0。
 * 其他子命令、错误长度、非 0/1 参数通过统一错误请求接口上报。
 *
 * i_req_valid 为单周期请求事件，子命令由本模块识别；Payload 经
 * Dispatcher 从 Parser 的 1clk 同步读 RAM 读取。正常响应先通过
 * rsp_wr_* 写入外部响应 RAM，再产生单周期 o_rsp_valid。
 * i_req_seq 保留统一请求接口，发送链路负责沿用请求的 CMD/SEQ。
 *
 * 系统保证单条指令一收一发，不增加 busy 检测、队列或完成输入。
 * i_abort 只中止当前处理，不回滚已经生效的测试标志。
 * i_rst_n 为异步低有效复位。
 */
module demo_ctrl (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_abort,
    input  wire        i_req_valid,
    input  wire [7:0]  i_req_cmd,
    input  wire [7:0]  i_req_seq,
    input  wire [15:0] i_req_length,

    output wire [10:0] o_payload_rd_addr,
    input  wire [7:0]  i_payload_rd_data,

    output reg         o_rsp_wr_en,
    output reg  [10:0] o_rsp_wr_addr,
    output reg  [7:0]  o_rsp_wr_data,
    output reg  [15:0] o_rsp_length,
    output reg         o_rsp_valid,
    output reg         o_error_valid,
    output reg  [7:0]  o_error_code,

    output reg         o_demo_enable
);

    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_READ_WAIT = 3'd1;
    localparam [2:0] ST_READ_BYTE = 3'd2;
    localparam [2:0] ST_RSP_WRITE = 3'd3;
    localparam [2:0] ST_RSP_DONE  = 3'd4;

    reg [2:0] state;
    reg       read_enable;
    reg       rsp_index;

    /* 本示例的写命令只需要读取 Payload 第一个字节。 */
    assign o_payload_rd_addr = 11'd0;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state         <= ST_IDLE;
            read_enable   <= 1'b0;
            rsp_index     <= 1'b0;
            o_demo_enable <= 1'b0;
            o_rsp_wr_en   <= 1'b0;
            o_rsp_wr_addr <= 11'd0;
            o_rsp_wr_data <= 8'd0;
            o_rsp_length  <= 16'd0;
            o_rsp_valid   <= 1'b0;
            o_error_valid <= 1'b0;
            o_error_code  <= 8'd0;
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
                            rsp_index <= 1'b0;
                            case (i_req_cmd)
                                `COMM_CMD_CTRL_READ: begin
                                    if (i_req_length == 16'd0) begin
                                        read_enable  <= o_demo_enable;
                                        o_rsp_length <= 16'd2;
                                        state        <= ST_RSP_WRITE;
                                    end else begin
                                        o_error_valid <= 1'b1;
                                        o_error_code  <= `COMM_ERROR_LENGTH;
                                    end
                                end
                                `COMM_CMD_CTRL_WRITE: begin
                                    if (i_req_length == 16'd1) begin
                                        o_rsp_length <= 16'd1;
                                        state        <= ST_READ_WAIT;
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
                        /* 等待当前选通模块的同步 RAM 读数据就绪。 */
                        state <= ST_READ_BYTE;
                    end

                    ST_READ_BYTE: begin
                        if ((i_payload_rd_data == 8'd0) ||
                            (i_payload_rd_data == 8'd1)) begin
                            o_demo_enable <= i_payload_rd_data[0];
                            state         <= ST_RSP_WRITE;
                        end else begin
                            o_error_valid <= 1'b1;
                            o_error_code  <= `COMM_ERROR_PARAM;
                            state         <= ST_IDLE;
                        end
                    end

                    ST_RSP_WRITE: begin
                        o_rsp_wr_en   <= 1'b1;
                        o_rsp_wr_addr <= {10'd0, rsp_index};
                        if (!rsp_index) begin
                            o_rsp_wr_data <= `COMM_STATUS_SUCCESS;
                        end else begin
                            o_rsp_wr_data <= {7'd0, read_enable};
                        end
                        if ((o_rsp_length == 16'd1) || rsp_index) begin
                            state <= ST_RSP_DONE;
                        end else begin
                            rsp_index <= 1'b1;
                        end
                    end

                    ST_RSP_DONE: begin
                        /* 响应数据写完后再发出一次提交事件。 */
                        o_rsp_valid <= 1'b1;
                        state       <= ST_IDLE;
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
