`timescale 1ns / 1ps

/*
 * UDP 请求帧解析器（单事务）
 *
 * 协议：CMD(1) | SEQ(1) | LENGTH(2, BE) | PAYLOAD(N) | CRC_H | CRC_L
 *       CRC-16/MODBUS 覆盖 CMD .. PAYLOAD，初值 FFFF，多项式 A001。
 *
 * 与 UART frame_parser 一样：Payload 写内部 RAM，校验成功后 o_frame_valid
 * 脉冲提交，后级同步读 RAM；i_frame_done 释放当前事务。
 *
 * 前提：i_rx_length 是当前 UDP Payload 的总字节数，在首个 i_rx_valid
 *       周期已有效；每个有效字节只出现一次，长度与字节流一致。
 *       UDP 核没有提供 SOF/TLAST，本模块按 i_rx_length 计数识别包尾。
 *       忙期间整包丢弃，不排队。去重/缓存响应由后续事务层实现。
 *
 * 复位：i_rst_n 为低有效同步复位；所有输入与 i_clk 同一时钟域。
 * RAM：复用工程现有 ip_ram_udp（1024 x 8，简单双口 RAM）。
 */
module udp_frame_parser #(
    parameter integer CLK_FREQ_HZ           = 100000000,
    parameter integer MAX_PAYLOAD_LENGTH    = 1024,
    parameter integer RX_TIMEOUT_MS         = 10,
    parameter integer TRANSACTION_TIMEOUT_MS = 1000
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    // UDP/IP 核应用层 RX（i_rx_length 包含本协议的全部字段）
    input  wire [7:0]  i_rx_byte,
    input  wire        i_rx_valid,
    input  wire [15:0] i_rx_length,

    // 单事务完成：业务处理及响应发送完成后置位一个周期
    input  wire        i_frame_done,
    output wire        o_busy,

    // 已校验请求：仅 o_frame_valid 为单周期脉冲，其余上下文保持到下次请求
    output reg         o_frame_valid,
    output reg  [7:0]  o_cmd,
    output reg  [7:0]  o_seq,
    output reg  [15:0] o_payload_length,

    // Payload RAM：地址从 0 开始，读数据延迟一个 i_clk 周期
    input  wire [10:0] i_payload_rd_addr,
    output wire [7:0]  o_payload_rd_data,

    // 单周期诊断脉冲（无业务错误响应）
    output reg         o_rx_timeout,
    output reg         o_length_error,
    output reg         o_crc_error,
    output reg         o_transaction_timeout
);

    localparam [2:0] ST_IDLE  = 3'd0,
                     ST_RECV  = 3'd1,
                     ST_DROP  = 3'd2,
                     ST_BUSY  = 3'd3,
                     ST_REARM = 3'd4;
    localparam integer RX_TIMEOUT_CYCLES =
        (CLK_FREQ_HZ / 1000) * RX_TIMEOUT_MS;
    localparam integer TRANSACTION_TIMEOUT_CYCLES =
        (CLK_FREQ_HZ / 1000) * TRANSACTION_TIMEOUT_MS;

    reg [2:0]  state;
    reg [15:0] packet_length;
    reg [15:0] byte_index;         // 下一有效字节在 UDP Payload 中的索引
    reg [7:0]  crc_high;
    reg [31:0] rx_timeout_count;
    reg [31:0] transaction_timeout_count;

    assign o_busy = (state == ST_BUSY);

    // 第一个字节 CMD 同拍初始化 CRC；之后只累计到 Payload 末字节。
    wire crc_init = (state == ST_IDLE) && i_rx_valid;
    wire crc_data_valid = crc_init ||
                          ((state == ST_RECV) && i_rx_valid &&
                           (byte_index < packet_length - 16'd2));
    wire [15:0] crc_value;

    crc16_modbus u_crc16_modbus (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),
        .i_init       (crc_init),
        .i_data_valid (crc_data_valid),
        .i_data       (i_rx_byte),
        .o_crc        (crc_value)
    );

    // Payload 写端地址从 0 递增；后级通过 B 口同步读 RAM。
    wire payload_ram_we = (state == ST_RECV) && i_rx_valid &&
                          (byte_index >= 16'd4) &&
                          (byte_index < packet_length - 16'd2);
    wire [10:0] payload_wr_addr = byte_index[10:0] - 11'd4;

    ip_ram_udp u_payload_ram (
        .dia   (i_rx_byte),
        .addra (payload_wr_addr[9:0]),
        .cea   (payload_ram_we),
        .clka  (i_clk),
        .dob   (o_payload_rd_data),
        .addrb (i_payload_rd_addr[9:0]),
        .ceb   (1'b1),
        .clkb  (i_clk)
    );

    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            state                     <= ST_IDLE;
            packet_length             <= 16'd0;
            byte_index                <= 16'd0;
            crc_high                  <= 8'd0;
            rx_timeout_count          <= 32'd0;
            transaction_timeout_count <= 32'd0;
            o_frame_valid             <= 1'b0;
            o_cmd                     <= 8'd0;
            o_seq                     <= 8'd0;
            o_payload_length          <= 16'd0;
            o_rx_timeout              <= 1'b0;
            o_length_error            <= 1'b0;
            o_crc_error               <= 1'b0;
            o_transaction_timeout     <= 1'b0;
        end else begin
            o_frame_valid         <= 1'b0;
            o_rx_timeout          <= 1'b0;
            o_length_error        <= 1'b0;
            o_crc_error           <= 1'b0;
            o_transaction_timeout <= 1'b0;

            case (state)
                ST_IDLE: begin
                    rx_timeout_count          <= 32'd0;
                    transaction_timeout_count <= 32'd0;
                    if (i_rx_valid) begin
                        packet_length <= i_rx_length;
                        byte_index    <= 16'd1;
                        o_cmd         <= i_rx_byte;
                        if ((i_rx_length < 16'd6) ||
                            (i_rx_length > MAX_PAYLOAD_LENGTH + 6)) begin
                            o_length_error <= 1'b1;
                            state <= ST_DROP;
                        end else begin
                            state <= ST_RECV;
                        end
                    end
                end

                ST_RECV: begin
                    if (i_rx_valid) begin
                        rx_timeout_count <= 32'd0;
                        byte_index <= byte_index + 16'd1;
                        if (byte_index == 16'd1) begin
                            o_seq <= i_rx_byte;
                        end else if (byte_index == 16'd2) begin
                            o_payload_length[15:8] <= i_rx_byte;
                        end else if (byte_index == 16'd3) begin
                            o_payload_length[7:0] <= i_rx_byte;
                            // 2 CMD/SEQ + 2 LENGTH + 2 CRC = 6 字节固定开销。
                            if (({o_payload_length[15:8], i_rx_byte} >
                                 MAX_PAYLOAD_LENGTH) ||
                                ({1'b0, o_payload_length[15:8], i_rx_byte} +
                                 17'd6 != {1'b0, packet_length})) begin
                                o_length_error <= 1'b1;
                                state <= ST_DROP;
                            end
                        end else if (byte_index == packet_length - 16'd2) begin
                            crc_high <= i_rx_byte;
                        end else if (byte_index == packet_length - 16'd1) begin
                            if ({crc_high, i_rx_byte} == crc_value) begin
                                o_frame_valid <= 1'b1;
                                state <= ST_BUSY;
                                transaction_timeout_count <= 32'd0;
                            end else begin
                                o_crc_error <= 1'b1;
                                state <= ST_IDLE;
                            end
                        end
                    end else if (RX_TIMEOUT_CYCLES <= 1 ||
                                 rx_timeout_count >= RX_TIMEOUT_CYCLES - 1) begin
                        o_rx_timeout <= 1'b1;
                        rx_timeout_count <= 32'd0;
                        state <= ST_IDLE;
                    end else begin
                        rx_timeout_count <= rx_timeout_count + 1'b1;
                    end
                end

                ST_DROP: begin
                    // 长度不合法时吞完此 UDP Payload，避免尾字节被当成新 CMD。
                    if (i_rx_valid) begin
                        rx_timeout_count <= 32'd0;
                        if (byte_index >= packet_length - 16'd1)
                            state <= ST_IDLE;
                        else
                            byte_index <= byte_index + 16'd1;
                    end else if (RX_TIMEOUT_CYCLES <= 1 ||
                                 rx_timeout_count >= RX_TIMEOUT_CYCLES - 1) begin
                        o_rx_timeout <= 1'b1;
                        rx_timeout_count <= 32'd0;
                        state <= ST_IDLE;
                    end else begin
                        rx_timeout_count <= rx_timeout_count + 1'b1;
                    end
                end

                ST_BUSY: begin
                    // 请求上下文及 RAM 不被新报文改写，直至完成或超时。
                    if (i_frame_done) begin
                        // 完成时若正收到被忽略的报文，等待数据流结束再接新帧。
                        state <= i_rx_valid ? ST_REARM : ST_IDLE;
                        transaction_timeout_count <= 32'd0;
                    end else if (TRANSACTION_TIMEOUT_CYCLES <= 1 ||
                                 transaction_timeout_count >=
                                 TRANSACTION_TIMEOUT_CYCLES - 1) begin
                        o_transaction_timeout <= 1'b1;
                        transaction_timeout_count <= 32'd0;
                        state <= i_rx_valid ? ST_REARM : ST_IDLE;
                    end else begin
                        transaction_timeout_count <=
                            transaction_timeout_count + 1'b1;
                    end
                end

                ST_REARM: begin
                    // UDP 核当前接口无 SOF/TLAST，只能利用字节流空隙重同步。
                    if (!i_rx_valid)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
