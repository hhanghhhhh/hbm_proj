`timescale 1ns / 1ps

/*
 * UDP 响应帧发送器（单事务）
 *
 * 帧格式：CMD | SEQ | LENGTH_H | LENGTH_L | PAYLOAD | CRC_H | CRC_L
 * CRC-16/MODBUS 覆盖 CMD 至 PAYLOAD，CRC 高字节先发。
 * 上游先写完响应 RAM，再以 i_rsp_valid 脉冲提交（LENGTH 包含 STATUS 字节）。
 *
 * 复用 crc16_modbus 和工程现有 ip_ram_udp；两个模块和本模块同一 i_clk。
 * ACK 后每拍连续输出一个有效字节；i_udp_tx_ready 仅用于发送前等待就绪，
 * 不作为发送过程的逐字节 backpressure。需确认 UDP IP 的该接口时序。
 * o_tx_done 表示整包数据已交给 UDP IP，不代表以太网物理发送完成。
 * 发送期间响应 RAM 不可改写；ACK 后 abort 只屏蔽 done，不截断 UDP 包。
 */
module udp_tx_frame_builder #(
    parameter integer MAX_PAYLOAD_LENGTH = 1024
) (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_abort,

    // 业务响应 Payload RAM 写口（PAYLOAD = STATUS + DATA）
    input  wire        i_rsp_wr_en,
    input  wire [10:0] i_rsp_wr_addr,
    input  wire [7:0]  i_rsp_wr_data,
    input  wire [15:0] i_rsp_length,
    input  wire        i_rsp_valid,

    // 当前请求上下文
    input  wire [7:0]  i_req_cmd,
    input  wire [7:0]  i_req_seq,

    // UDP/IP 核应用层发送接口
    input  wire        i_udp_tx_ready,
    input  wire        i_udp_tx_ack,
    output wire        o_udp_tx_request,
    output wire [15:0] o_udp_tx_length,
    output wire        o_udp_tx_data_valid,
    output reg  [7:0]  o_udp_tx_data,

    output wire        o_busy,
    output reg         o_tx_done,
    output reg         o_length_error
);

    localparam [1:0] ST_IDLE       = 2'd0,
                     ST_WAIT_READY = 2'd1,
                     ST_WAIT_ACK   = 2'd2,
                     ST_SEND       = 2'd3;

    reg [1:0]  state;
    reg [7:0]  req_cmd;
    reg [7:0]  req_seq;
    reg [15:0] rsp_length;
    reg [15:0] send_index;        // 当前发送字节的帧内偏移，从 0 开始
    reg        aborted;

    wire [15:0] udp_length = rsp_length + 16'd6;
    wire [15:0] crc_begin  = rsp_length + 16'd4;
    wire [15:0] last_index = rsp_length + 16'd5;
    wire [15:0] crc_value;
    wire [7:0]  ram_rd_data;

    wire rsp_length_ok = (i_rsp_length >= 16'd1) &&
                         (i_rsp_length <= MAX_PAYLOAD_LENGTH);
    wire rsp_accept = (state == ST_IDLE) && i_rsp_valid &&
                      !i_abort && rsp_length_ok;

    assign o_busy              = (state != ST_IDLE);
    assign o_udp_tx_request    = (state == ST_WAIT_ACK);
    assign o_udp_tx_length     = udp_length;
    assign o_udp_tx_data_valid = (state == ST_SEND);

    // 在响应提交时初始化 CRC，发送 CMD/SEQ/LENGTH/PAYLOAD 时按实际节拍累加。
    wire crc_init = rsp_accept;
    wire crc_data_valid = (state == ST_SEND) && (send_index < crc_begin);

    crc16_modbus u_crc16_modbus (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),
        .i_init       (crc_init),
        .i_data_valid (crc_data_valid),
        .i_data       (o_udp_tx_data),
        .o_crc        (crc_value)
    );

    /*
     * 同步读 RAM：头部阶段预读地址 0；发送 Payload[n] 的同一拍
     * 预读 Payload[n+1]，确保 ACK 后字节流连续无气泡。
     * 最后一个 Payload 不需要预读下一个地址。
     */
    wire [10:0] ram_rd_addr =
        ((state == ST_SEND) &&
         (send_index >= 16'd4) &&
         (send_index < rsp_length + 16'd3))
        ? (send_index[10:0] - 11'd3)
        : 11'd0;

    ip_ram_udp u_response_ram (
        .dia   (i_rsp_wr_data),
        .addra (i_rsp_wr_addr[9:0]),
        .cea   (i_rsp_wr_en && (state == ST_IDLE)), 
        .clka  (i_clk),
        .dob   (ram_rd_data),
        .addrb (ram_rd_addr[9:0]),
        .ceb   (1'b1),
        .clkb  (i_clk)
    );

    // 按索引输出完整 UDP Payload，CRC 在最后一个业务字节发送后已更新。
    always @* begin
        case (send_index)
            16'd0: o_udp_tx_data = req_cmd;
            16'd1: o_udp_tx_data = req_seq;
            16'd2: o_udp_tx_data = rsp_length[15:8];
            16'd3: o_udp_tx_data = rsp_length[7:0];
            default: begin
                if (send_index < crc_begin)
                    o_udp_tx_data = ram_rd_data;
                else if (send_index == crc_begin)
                    o_udp_tx_data = crc_value[15:8];
                else
                    o_udp_tx_data = crc_value[7:0];
            end
        endcase
    end

    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            state          <= ST_IDLE;
            req_cmd        <= 8'd0;
            req_seq        <= 8'd0;
            rsp_length     <= 16'd0;
            send_index     <= 16'd0;
            aborted        <= 1'b0;
            o_tx_done      <= 1'b0;
            o_length_error <= 1'b0;
        end else begin
            o_tx_done      <= 1'b0;
            o_length_error <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (i_rsp_valid && !i_abort) begin
                        if (!rsp_length_ok) begin
                            o_length_error <= 1'b1;
                        end else begin
                            req_cmd    <= i_req_cmd;
                            req_seq    <= i_req_seq;
                            rsp_length <= i_rsp_length;
                            send_index <= 16'd0;
                            aborted    <= 1'b0;
                            state      <= ST_WAIT_READY;
                        end
                    end
                end

                ST_WAIT_READY: begin
                    if (i_abort)
                        state <= ST_IDLE;
                    else if (i_udp_tx_ready)
                        state <= ST_WAIT_ACK;
                end

                ST_WAIT_ACK: begin
                    // ACK 与 abort 同拍时，UDP 核可能已接受请求，必须发完整包。
                    if (i_udp_tx_ack) begin
                        send_index <= 16'd0;
                        aborted    <= i_abort;
                        state      <= ST_SEND;
                    end else if (i_abort) begin
                        state <= ST_IDLE;
                    end
                end

                ST_SEND: begin
                    // ACK 后不可中断字节流，否则会留下不完整的 UDP 报文。
                    if (i_abort)
                        aborted <= 1'b1;

                    if (send_index == last_index) begin
                        state <= ST_IDLE;
                        if (!aborted && !i_abort)
                            o_tx_done <= 1'b1;
                    end else begin
                        send_index <= send_index + 16'd1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
