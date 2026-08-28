`timescale 1ns / 1ps

/*
 * 响应帧缓存、组帧与 RS485 发送方向控制模块。
 *
 * 内部例化 ip_ram_uart_tx（2048 x 8，B 口同步读延迟 1clk）和
 * crc16_modbus。A 口接 Response Buffer 的响应写接口；i_rsp_valid
 * 到达时锁存请求 ADDR/CMD/SEQ 及响应 LENGTH，然后依次发送：
 * 55 AA | ADDR | CMD | SEQ | LENGTH_H LENGTH_L | PAYLOAD | CRC_H CRC_L。
 * LENGTH 允许为 0。CRC-16/MODBUS 只累计实际握手的 ADDR 至 PAYLOAD，
 * SOF 和 CRC 字段不参与累计，CRC 字段采用大端顺序。
 *
 * UART TX 保持外部例化，使用 o_tx_byte/o_tx_valid/i_tx_ready 握手。
 * valid 是保持到握手的有效电平，不是单周期事件；ready 为 0 时，
 * 当前字节及 valid 保持不变。i_tx_ready 必须使用 UART_TX_Direct
 * 的空闲指示：它在整个起始位、数据位和停止位期间均为 0，不能接成
 * 带 FIFO 的“可继续入队”信号。波特率由外部 UART 配置，工程默认
 * 为 460800；本模块用 ready 等待物理发送结束，不重复计算字节时间。
 *
 * i_rsp_valid -> 切换发送方向 -> 前延时 -> 发送完整帧 -> 等待最后
 * 停止位完成 -> 后延时 -> 切回接收方向，同时产生单周期 o_tx_done。
 * o_rs485_tx_en 为 1 表示发送，为 0 表示接收，可由顶层连接 DE/RE。
 * o_tx_done 接 Parser 的 frame_done，不在最后 CRC 字节入 UART 时产生。
 *
 * i_abort 接 Parser 的事务超时。中止时撤销尚未握手的字节，不提交
 * 后续字节；已经被 UART 接收的当前字节允许完整发完，再经过后延时
 * 切回接收，不产生 o_tx_done。异步复位则立即回到接收状态。
 *
 * 系统严格单事务：先写完 Payload，再提交 rsp_valid；发送期间上游
 * 不再写 RAM 或提交新响应。本模块不增加队列、长度检查或重试逻辑。
 * 主机下一次发送应避开后延时及板级收发器释放时间，不能只依据收到
 * 最后一个响应字节便立即驱动总线。abort 后重试也遵循相同方向约束。
 *
 * 前后延时默认各 10us，为型号未确定时的保守初值，需按实际器件调整。
 * 参考：MAX485 驱动使能最大 70ns；SN65HVD3085E 从关断使能最大 4.5us
 * （均为对应手册测试条件）。此默认值不是所有 RS485 收发器的保证。
 * https://www.analog.com/media/en/technical-documentation/data-sheets/MAX1487-MAX491.pdf
 * https://www.ti.com/lit/ds/symlink/sn65hvd3082e.pdf
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
