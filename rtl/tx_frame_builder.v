`timescale 1ns / 1ps

/*
 * 模块说明
 *
 * 功能：
 * - 缓存响应 Payload，组装协议响应帧，并控制逐字节 UART 发送及 RS485 方向。
 *
 * 关键数据：
 * - 帧格式为 55 AA | ADDR | CMD | SEQ | LENGTH_H | LENGTH_L | PAYLOAD |
 *   CRC_H | CRC_L；CRC-16/MODBUS 覆盖两个 SOF 字节至 Payload。
 * - 内部响应 RAM 为 2048x8；上游必须先写完 Payload，再提交 i_rsp_valid。
 *
 * 关键约束：
 * - 系统只允许一个响应在途，发送期间上游不得改写 RAM 或提交新响应。
 * - i_tx_ready 必须表示 UART 物理发送完全空闲，在当前字节停止位结束前保持为 0，
 *   不能连接为带 FIFO 发送器的“可继续写入”指示。
 * - RS485 前后延时参数必须按实际收发器和板级方向切换要求设置。
 *
 * 特殊行为：
 * - o_tx_done 在最后字节停止位结束、后延时完成且 RS485 已切回接收后产生；
 *   主机不能仅凭收到最后一个字节立即驱动总线。
 * - i_abort 停止提交后续字节，但允许 UART 发完已接收字节，再经后延时释放方向；
 *   被中止的事务不产生 o_tx_done。
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

    /* 头部索引 0/1 为 SOF，其余为 ADDR/CMD/SEQ/LENGTH；全部参与 CRC。 */
    assign crc_data_valid = tx_accept &&
                            ((state == ST_HEADER) ||
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
    ip_ram_uart u_response_ram (
        .dia   (i_rsp_wr_data),
        .addra (i_rsp_wr_addr),
        .cea   (i_rsp_wr_en),
        .clka  (i_clk),
        .dob   (ram_rd_data),
        .addrb (ram_rd_addr),
        .ceb   (1'b1),
        .clkb  (i_clk)
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
