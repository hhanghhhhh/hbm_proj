`timescale 1ns / 1ps

/*
 * Module Contract
 *
 * 模块职责：
 * - 缓存响应 Payload，组装完整协议响应帧，并控制逐字节 UART 握手和 RS485 方向。
 * - 对 ADDR 至 PAYLOAD 的实际发送字节计算 CRC-16/MODBUS。
 * - 不负责：产生业务响应、检查响应长度、缓存多个响应、重试或配置 UART 波特率。
 *
 * 输入事务：
 * - 上游先用 i_rsp_wr_en 将全部 Payload 写入内部 2048x8 RAM，再以 i_rsp_valid 提交。
 * - 空闲时 i_rsp_valid=1 的上升沿锁存 i_req_addr/i_req_cmd/i_req_seq/i_rsp_length。
 * - 发送期间不接收或排队新的响应提交；LENGTH 允许为 0。
 *
 * 输出事务：
 * - 帧顺序为 55 AA|ADDR|CMD|SEQ|LENGTH_H|LENGTH_L|PAYLOAD|CRC_H|CRC_L。
 * - CRC 不含 SOF 和 CRC 字段；CRC 字段以高字节在前发送。
 * - o_tx_valid 保持到与 i_tx_ready 握手；阻塞期间 o_tx_byte 保持当前字节。
 * - 最后 CRC 字节的 UART 停止位完成并经过后延时后，释放方向并产生 1clk o_tx_done。
 *
 * 关键时序：
 * - 提交后先置 o_rs485_tx_en=1并等待 PRE_DELAY_CYCLES，之后才提交首字节。
 * - Payload RAM B 口为同步读，地址更新后等待一拍再加载发送字节。
 * - i_tx_ready 必须表示 UART 完全空闲；每次握手后需保持低直到该字节停止位结束。
 * - 完整帧发送后等待 UART ready，再执行 POST_DELAY_CYCLES 并将 o_rs485_tx_en 清零。
 *
 * 异常与恢复：
 * - reset：异步低有效，立即撤销 valid、释放 RS485 方向并回到空闲。
 * - abort：同拍屏蔽新 UART 握手，停止后续字节；已被 UART 接收的字节允许发送完。
 * - 若 abort 时已进入发送方向，模块等待 UART 空闲及后延时后释放方向，不产生 o_tx_done。
 *
 * 使用约束：
 * - 上层必须保证单事务、Payload 长度不超过 RAM 容量，且发送期间不写 RAM。
 * - o_tx_done 才表示总线方向已释放；主机不能仅凭收到最后字节立即驱动总线。
 * - 前后延时参数必须按实际 RS485 收发器使能/关断时间和板级约束设置。
 *
 * 参考：
 * - COMMUNICATION_PROTOCOL.md：响应帧格式和 CRC 覆盖范围。
 * - TX_FRAME_BUILDER.md：发送链路与 RS485 方向时序。
 */
module tx_frame_builder #(
    parameter integer CLK_FREQ_HZ        = 100000000,
    parameter integer RS485_PRE_DELAY_US = 10,
    parameter integer RS485_POST_DELAY_US = 10
) (
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_abort,

    input  wire        i_rsp_wr_en,
    input  wire [10:0] i_rsp_wr_addr,
    input  wire [7:0]  i_rsp_wr_data,
    input  wire [15:0] i_rsp_length,
    input  wire        i_rsp_valid,

    input  wire [7:0]  i_req_addr,
    input  wire [7:0]  i_req_cmd,
    input  wire [7:0]  i_req_seq,

    output reg  [7:0]  o_tx_byte,
    output wire        o_tx_valid,
    input  wire        i_tx_ready,
    output reg         o_rs485_tx_en,
    output reg         o_tx_done
);

    /* 使用 64 位中间乘积，并向上取整，避免微秒换算时先除法损失精度。 */
    localparam integer PRE_DELAY_CYCLES =
        (64'd1 * CLK_FREQ_HZ * RS485_PRE_DELAY_US + 64'd999999) / 64'd1000000;
    localparam integer POST_DELAY_CYCLES =
        (64'd1 * CLK_FREQ_HZ * RS485_POST_DELAY_US + 64'd999999) / 64'd1000000;

    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_PRE_DELAY    = 4'd1;
    localparam [3:0] ST_HEADER       = 4'd2;
    localparam [3:0] ST_PAYLOAD_WAIT = 4'd3;
    localparam [3:0] ST_PAYLOAD_LOAD = 4'd4;
    localparam [3:0] ST_PAYLOAD_SEND = 4'd5;
    localparam [3:0] ST_CRC_LOAD     = 4'd6;
    localparam [3:0] ST_CRC_HIGH     = 4'd7;
    localparam [3:0] ST_CRC_LOW      = 4'd8;
    localparam [3:0] ST_UART_DRAIN   = 4'd9;
    localparam [3:0] ST_POST_DELAY   = 4'd10;

    reg [3:0]  state;
    reg [7:0]  req_addr;
    reg [7:0]  req_cmd;
    reg [7:0]  req_seq;
    reg [15:0] rsp_length;
    reg [2:0]  header_index;
    reg [10:0] ram_rd_addr;
    reg [31:0] delay_count;
    reg        tx_valid;
    reg        transaction_aborted;
    reg        crc_init;
    reg [15:0] crc_saved;

    wire [7:0]  ram_rd_data;
    wire [15:0] crc_value;
    wire        tx_accept;
    wire        crc_data_valid;

    /* abort 同周期禁止新的 UART 握手，已接收的字节由 UART 自行发完。 */
    assign o_tx_valid = tx_valid && !i_abort;
    assign tx_accept = o_tx_valid && i_tx_ready;

    /* 头部索引 0/1 为 SOF，其余为 ADDR/CMD/SEQ/LENGTH。 */
    assign crc_data_valid = tx_accept &&
                            (((state == ST_HEADER) && (header_index >= 3'd2)) ||
                             (state == ST_PAYLOAD_SEND));

    crc16_modbus u_crc16_modbus (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),
        .i_init       (crc_init),
        .i_data_valid (crc_data_valid),
        .i_data       (o_tx_byte),
        .o_crc        (crc_value)
    );

    /* A 口由业务响应源写入，B 口由发送状态机同步读取，不清空 RAM 内容。 */
    ip_ram_uart_tx u_response_ram (
        .doa   (),
        .dia   (i_rsp_wr_data),
        .addra (i_rsp_wr_addr),
        .cea   (1'b1),
        .clka  (i_clk),
        .wea   (i_rsp_wr_en),
        .rsta  (~i_rst_n),
        .ocea  (1'b1),
        .dob   (ram_rd_data),
        .dib   (8'd0),
        .addrb (ram_rd_addr),
        .ceb   (1'b1),
        .clkb  (i_clk),
        .web   (1'b0),
        .rstb  (~i_rst_n),
        .oceb  (1'b1)
    );

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            state               <= ST_IDLE;
            req_addr            <= 8'd0;
            req_cmd             <= 8'd0;
            req_seq             <= 8'd0;
            rsp_length          <= 16'd0;
            header_index        <= 3'd0;
            ram_rd_addr         <= 11'd0;
            delay_count         <= 32'd0;
            tx_valid            <= 1'b0;
            transaction_aborted <= 1'b0;
            crc_init            <= 1'b0;
            crc_saved           <= 16'd0;
            o_tx_byte           <= 8'd0;
            o_rs485_tx_en       <= 1'b0;
            o_tx_done           <= 1'b0;
        end else begin
            o_tx_done <= 1'b0;
            crc_init  <= 1'b0;

            if (i_abort) begin
                tx_valid            <= 1'b0;
                transaction_aborted <= 1'b1;
                delay_count         <= 32'd0;
                if (o_rs485_tx_en) begin
                    /* 不立即关闭驱动，等待 UART 中当前字节发完。 */
                    state <= ST_UART_DRAIN;
                end else begin
                    state <= ST_IDLE;
                end
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (i_rsp_valid) begin
                            /* 提交时锁存字段，避免错误响应 MUX 后续切回正常源。 */
                            req_addr            <= i_req_addr;
                            req_cmd             <= i_req_cmd;
                            req_seq             <= i_req_seq;
                            rsp_length          <= i_rsp_length;
                            header_index        <= 3'd0;
                            ram_rd_addr         <= 11'd0;
                            delay_count         <= 32'd0;
                            transaction_aborted <= 1'b0;
                            crc_init            <= 1'b1;
                            o_rs485_tx_en       <= 1'b1;
                            state               <= ST_PRE_DELAY;
                        end
                    end

                    ST_PRE_DELAY: begin
                        if ((PRE_DELAY_CYCLES == 0) ||
                            (delay_count == PRE_DELAY_CYCLES - 1)) begin
                            o_tx_byte <= 8'h55;
                            tx_valid  <= 1'b1;
                            state     <= ST_HEADER;
                        end else begin
                            delay_count <= delay_count + 1'b1;
                        end
                    end

                    ST_HEADER: begin
                        /* 只有当前字节握手成功才切换数据，阻塞时保持输出。 */
                        if (tx_accept) begin
                            case (header_index)
                                3'd0: o_tx_byte <= 8'hAA;
                                3'd1: o_tx_byte <= req_addr;
                                3'd2: o_tx_byte <= req_cmd;
                                3'd3: o_tx_byte <= req_seq;
                                3'd4: o_tx_byte <= rsp_length[15:8];
                                3'd5: o_tx_byte <= rsp_length[7:0];
                                3'd6: begin
                                    tx_valid <= 1'b0;
                                    if (rsp_length == 16'd0) begin
                                        state <= ST_CRC_LOAD;
                                    end else begin
                                        state <= ST_PAYLOAD_WAIT;
                                    end
                                end
                            endcase
                            header_index <= header_index + 1'b1;
                        end
                    end

                    ST_PAYLOAD_WAIT: begin
                        /* 新地址在本时钟沿进入同步 RAM，下一状态再取返回值。 */
                        state <= ST_PAYLOAD_LOAD;
                    end

                    ST_PAYLOAD_LOAD: begin
                        o_tx_byte <= ram_rd_data;
                        tx_valid  <= 1'b1;
                        state     <= ST_PAYLOAD_SEND;
                    end

                    ST_PAYLOAD_SEND: begin
                        if (tx_accept) begin
                            tx_valid <= 1'b0;
                            if ({5'd0, ram_rd_addr} == rsp_length - 16'd1) begin
                                state <= ST_CRC_LOAD;
                            end else begin
                                ram_rd_addr <= ram_rd_addr + 1'b1;
                                state       <= ST_PAYLOAD_WAIT;
                            end
                        end
                    end

                    ST_CRC_LOAD: begin
                        /* 前一时钟沿已累计最后一个数据字节，此时 CRC 完整有效。 */
                        crc_saved <= crc_value;
                        o_tx_byte <= crc_value[15:8];
                        tx_valid  <= 1'b1;
                        state     <= ST_CRC_HIGH;
                    end

                    ST_CRC_HIGH: begin
                        if (tx_accept) begin
                            o_tx_byte <= crc_saved[7:0];
                            state     <= ST_CRC_LOW;
                        end
                    end

                    ST_CRC_LOW: begin
                        if (tx_accept) begin
                            tx_valid <= 1'b0;
                            state    <= ST_UART_DRAIN;
                        end
                    end

                    ST_UART_DRAIN: begin
                        /* 最后一次握手后 UART 会拉低 ready，停止位结束后再置高。 */
                        if (i_tx_ready) begin
                            delay_count <= 32'd0;
                            state       <= ST_POST_DELAY;
                        end
                    end

                    ST_POST_DELAY: begin
                        if ((POST_DELAY_CYCLES == 0) ||
                            (delay_count == POST_DELAY_CYCLES - 1)) begin
                            o_rs485_tx_en <= 1'b0;
                            if (!transaction_aborted) begin
                                o_tx_done <= 1'b1;
                            end
                            state <= ST_IDLE;
                        end else begin
                            delay_count <= delay_count + 1'b1;
                        end
                    end

                    default: begin
                        state         <= ST_IDLE;
                        tx_valid      <= 1'b0;
                        o_rs485_tx_en <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule
