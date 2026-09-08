`timescale 1ns / 1ps

/*
 * 模块说明
 *
 * 功能：
 * - 将 UART 字节流解析为请求帧，校验长度、CRC 和本机地址；合法 Payload
 *   写入内部 2048x8 RAM，并连同请求上下文提交给后级。
 *
 * 关键数据：
 * - 帧格式为 55 AA | ADDR | CMD | SEQ | LENGTH_H | LENGTH_L | PAYLOAD |
 *   CRC_H | CRC_L；CRC-16/MODBUS 覆盖从两个 SOF 字节到 Payload 的全部字节。
 * - LENGTH 允许 0..MAX_PAYLOAD_LENGTH，Payload 从 RAM 地址 0 连续存放。
 *
 * 关键约束：
 * - 系统只允许一个已提交事务在途；请求上下文和 Payload 保持有效，直到
 *   i_frame_done 或事务超时，期间所有新接收字节均被忽略且不排队。
 * - i_local_addr 必须在当前帧接收及最终地址判定期间保持稳定。
 *
 * 特殊行为：
 * - SOF 采用非重叠 55 AA 匹配；第二字节错误时，该字节不复用为下一帧的 55。
 * - 从首个 SOF 字节起监测字节间超时，阈值为 8N1 的 1.5 个字符时间。
 * - CRC、地址或接收格式错误仅产生诊断事件，不生成可交给业务层的请求。
 * - i_rst_n 在 i_clk 上升沿同步采样，与工程中常用的异步复位不同。
 */
module frame_parser #(
    parameter integer CLK_FREQ_HZ           = 100000000,
    parameter integer BAUD_RATE             = 460800,
    parameter integer MAX_PAYLOAD_LENGTH    = 2048,
    parameter integer TRANSACTION_TIMEOUT_MS = 1000
) (
    input  wire        i_clk,
    input  wire        i_rst_n,

    input  wire [7:0]  i_rx_byte,
    input  wire        i_rx_valid,
    input  wire [7:0]  i_local_addr,
    input  wire        i_frame_done,

    output reg         o_frame_valid,
    output reg  [7:0]  o_addr,
    output reg  [7:0]  o_cmd,
    output reg  [7:0]  o_seq,
    output reg  [15:0] o_payload_length,

    input  wire [10:0] i_payload_rd_addr,
    output wire [7:0]  o_payload_rd_data,

    output reg         o_rx_timeout,
    output reg         o_length_error,
    output reg         o_crc_error,
    output reg         o_addr_error,
    output reg         o_transaction_timeout
);

    /* 8N1 下 1.5 个字符时间等于 15 个波特位周期，向上取整为时钟周期数。 */
    localparam integer RX_TIMEOUT_CYCLES =
        ((CLK_FREQ_HZ * 15) + BAUD_RATE - 1) / BAUD_RATE;
    /* 先除以 1000，避免默认参数相乘时超出 32 位整数范围。 */
    localparam integer TRANSACTION_TIMEOUT_CYCLES =
        (CLK_FREQ_HZ / 1000) * TRANSACTION_TIMEOUT_MS;

    /* 单段式接收状态机：从两字节帧头依次推进到 CRC 低字节。 */
    localparam [3:0] ST_SOF_0   = 4'd0;
    localparam [3:0] ST_SOF_1   = 4'd1;
    localparam [3:0] ST_ADDR    = 4'd2;
    localparam [3:0] ST_CMD     = 4'd3;
    localparam [3:0] ST_SEQ     = 4'd4;
    localparam [3:0] ST_LEN_H   = 4'd5;
    localparam [3:0] ST_LEN_L   = 4'd6;
    localparam [3:0] ST_PAYLOAD = 4'd7;
    localparam [3:0] ST_CRC_H   = 4'd8;
    localparam [3:0] ST_CRC_L   = 4'd9;

    /* 当前合法请求提交后，request_busy 保持到完成或事务超时。 */
    reg [3:0]  state;
    reg        request_busy;
    reg [15:0] received_crc_high;
    reg [11:0] payload_byte_count;
    reg [10:0] payload_wr_addr;
    reg [31:0] rx_timeout_count;
    reg [31:0] transaction_timeout_count;

    /* CRC 子模块采用初始化脉冲和逐字节有效脉冲驱动。 */
    reg        crc_init;
    reg        crc_data_valid;
    reg [7:0]  crc_data;
    wire [15:0] crc_value;

    /* 仅在 PAYLOAD 状态收到有效字节时写 RAM。 */
    wire       payload_ram_we;

    assign payload_ram_we = (!request_busy) &&
                            (state == ST_PAYLOAD) && i_rx_valid;

    /* CRC 从首个 SOF 字节开始累计，不包含接收到的 CRC 字段。 */
    crc16_modbus u_crc16_modbus (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),
        .i_init       (crc_init),
        .i_data_valid (crc_data_valid),
        .i_data       (crc_data),
        .o_crc        (crc_value)
    );

    /* A 口由解析器写入 Payload，B 口供后级业务模块同步读取。 */
    ip_ram_uart u_payload_ram (
        .dia   (i_rx_byte),
        .addra (payload_wr_addr),
        .cea   (payload_ram_we),
        .clka  (i_clk),
        .dob   (o_payload_rd_data),
        .addrb (i_payload_rd_addr),
        .ceb   (1'b1),
        .clkb  (i_clk)
    );

    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            state                     <= ST_SOF_0;
            request_busy              <= 1'b0;
            received_crc_high         <= 16'h0000;
            payload_byte_count        <= 12'd0;
            payload_wr_addr           <= 11'd0;
            rx_timeout_count          <= 32'd0;
            transaction_timeout_count <= 32'd0;
            crc_init                   <= 1'b0;
            crc_data_valid             <= 1'b0;
            crc_data                   <= 8'h00;
            o_frame_valid              <= 1'b0;
            o_addr                     <= 8'h00;
            o_cmd                      <= 8'h00;
            o_seq                      <= 8'h00;
            o_payload_length           <= 16'h0000;
            o_rx_timeout               <= 1'b0;
            o_length_error             <= 1'b0;
            o_crc_error                <= 1'b0;
            o_addr_error               <= 1'b0;
            o_transaction_timeout      <= 1'b0;
        end else begin
            /* 所有事件类输出和 CRC 控制信号默认清零，确保只保持一个周期。 */
            o_frame_valid         <= 1'b0;
            o_rx_timeout          <= 1'b0;
            o_length_error        <= 1'b0;
            o_crc_error           <= 1'b0;
            o_addr_error          <= 1'b0;
            o_transaction_timeout <= 1'b0;
            crc_init              <= 1'b0;
            crc_data_valid        <= 1'b0;

            if (request_busy) begin
                /* 忙期间忽略 RX，仅等待响应完成或事务看门狗超时。 */
                state            <= ST_SOF_0;
                rx_timeout_count <= 32'd0;

                if (i_frame_done) begin
                    request_busy              <= 1'b0;
                    transaction_timeout_count <= 32'd0;
                    o_addr                     <= 8'h00;
                    o_cmd                      <= 8'h00;
                    o_seq                      <= 8'h00;
                    o_payload_length           <= 16'h0000;
                end else if ((TRANSACTION_TIMEOUT_CYCLES <= 1) ||
                             (transaction_timeout_count >=
                              TRANSACTION_TIMEOUT_CYCLES - 1)) begin
                    request_busy              <= 1'b0;
                    transaction_timeout_count <= 32'd0;
                    o_transaction_timeout      <= 1'b1;
                    o_addr                     <= 8'h00;
                    o_cmd                      <= 8'h00;
                    o_seq                      <= 8'h00;
                    o_payload_length           <= 16'h0000;
                end else begin
                    transaction_timeout_count <= transaction_timeout_count + 1'b1;
                end
            end else begin
                transaction_timeout_count <= 32'd0;

                /* 完整 SOF 之后启用字节间计时，每收到一个字节重新计时。 */
                if (state == ST_SOF_0) begin
                    rx_timeout_count <= 32'd0;
                end else if (i_rx_valid) begin
                    rx_timeout_count <= 32'd0;
                end else if ((RX_TIMEOUT_CYCLES <= 1) ||
                             (rx_timeout_count >= RX_TIMEOUT_CYCLES - 1)) begin
                    state            <= ST_SOF_0;
                    rx_timeout_count <= 32'd0;
                    o_rx_timeout     <= 1'b1;
                end else begin
                    rx_timeout_count <= rx_timeout_count + 1'b1;
                end

                if (i_rx_valid) begin
                    case (state)
                        ST_SOF_0: begin
                            /* 搜索帧头首字节，并以 55 作为新一轮 CRC 的首字节。 */
                            if (i_rx_byte == 8'h55) begin
                                state          <= ST_SOF_1;
                                crc_init       <= 1'b1;
                                crc_data       <= 8'h55;
                                crc_data_valid <= 1'b1;
                            end
                        end

                        ST_SOF_1: begin
                            /* 不支持重叠匹配：第二字节错误时直接回到 ST_SOF_0。 */
                            if (i_rx_byte == 8'hAA) begin
                                state          <= ST_ADDR;
                                crc_data       <= 8'hAA;
                                crc_data_valid <= 1'b1;
                            end else begin
                                state <= ST_SOF_0;
                            end
                        end

                        ST_ADDR: begin
                            /* SOF 已累计，继续将 ADDR 及后续协议字节送入 CRC。 */
                            o_addr         <= i_rx_byte;
                            crc_data       <= i_rx_byte;
                            crc_data_valid <= 1'b1;
                            state          <= ST_CMD;
                        end

                        ST_CMD: begin
                            o_cmd          <= i_rx_byte;
                            crc_data       <= i_rx_byte;
                            crc_data_valid <= 1'b1;
                            state          <= ST_SEQ;
                        end

                        ST_SEQ: begin
                            o_seq          <= i_rx_byte;
                            crc_data       <= i_rx_byte;
                            crc_data_valid <= 1'b1;
                            state          <= ST_LEN_H;
                        end

                        ST_LEN_H: begin
                            o_payload_length[15:8] <= i_rx_byte;
                            crc_data                <= i_rx_byte;
                            crc_data_valid          <= 1'b1;
                            state                   <= ST_LEN_L;
                        end

                        ST_LEN_L: begin
                            /* LENGTH 为大端；零长度合法，超上限则立即丢弃。 */
                            o_payload_length[7:0] <= i_rx_byte;
                            crc_data               <= i_rx_byte;
                            crc_data_valid         <= 1'b1;
                            payload_byte_count     <= 12'd0;
                            payload_wr_addr        <= 11'd0;

                            if ({o_payload_length[15:8], i_rx_byte} >
                                MAX_PAYLOAD_LENGTH) begin
                                state          <= ST_SOF_0;
                                o_length_error <= 1'b1;
                            end else if ({o_payload_length[15:8], i_rx_byte} ==
                                         16'd0) begin
                                state <= ST_CRC_H;
                            end else begin
                                state <= ST_PAYLOAD;
                            end
                        end

                        ST_PAYLOAD: begin
                            /* RAM 写使能由当前状态与 i_rx_valid 组合产生。 */
                            crc_data       <= i_rx_byte;
                            crc_data_valid <= 1'b1;

                            if (payload_byte_count == o_payload_length - 1'b1) begin
                                state <= ST_CRC_H;
                            end else begin
                                payload_byte_count <= payload_byte_count + 1'b1;
                                payload_wr_addr    <= payload_wr_addr + 1'b1;
                            end
                        end

                        ST_CRC_H: begin
                            /* CRC 字段按大端顺序接收，高字节在前。 */
                            received_crc_high[15:8] <= i_rx_byte;
                            state                   <= ST_CRC_L;
                        end

                        ST_CRC_L: begin
                            received_crc_high[7:0] <= i_rx_byte;
                            state                  <= ST_SOF_0;

                            /* 先校验 CRC，再检查本机地址；任一失败均静默丢帧。 */
                            if ({received_crc_high[15:8], i_rx_byte} !=
                                crc_value) begin
                                o_crc_error <= 1'b1;
                            end else if (o_addr != i_local_addr) begin
                                o_addr_error <= 1'b1;
                            end else begin
                                o_frame_valid              <= 1'b1;
                                request_busy               <= 1'b1;
                                transaction_timeout_count  <= 32'd0;
                            end
                        end

                        default: begin
                            state <= ST_SOF_0;
                        end
                    endcase
                end
            end
        end
    end

endmodule
