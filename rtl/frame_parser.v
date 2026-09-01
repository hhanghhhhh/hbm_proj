`timescale 1ns / 1ps

/*
 * Module Contract
 *
 * 模块职责：
 * - 将 UART 字节流解析为完整请求帧，校验 LENGTH、CRC 和本机地址后提交给后级。
 * - Payload 在接收过程中写入内部双口 RAM；合法事务期间请求上下文和 Payload 保持可用。
 * - 提供接收超时、长度错误、CRC 错误、地址错误和事务超时的单周期诊断脉冲。
 * - 不负责：解释 CMD/Payload 业务含义、生成错误响应或发送响应帧。
 *
 * 输入事务：
 * - 每个 i_rx_valid=1 的时钟周期接收一个 i_rx_byte；帧格式遵循 COMMUNICATION_PROTOCOL.md。
 * - SOF 按非重叠 55 AA 匹配；第二字节不是 AA 时直接重新等待 55，错误字节不复用于新帧头。
 * - LENGTH 为大端，允许 0..MAX_PAYLOAD_LENGTH；Payload 从地址 0 起连续写入 RAM。
 * - CRC 从 ADDR 到 PAYLOAD 逐字节累计，不包含 SOF 和 CRC 字段；接收 CRC 高字节在前。
 *
 * 输出事务：
 * - 仅当 LENGTH 合法、CRC 正确且 ADDR==i_local_addr 时，产生 1clk 的 o_frame_valid。
 * - o_frame_valid 提交后，o_addr/o_cmd/o_seq/o_payload_length 和 Payload RAM 保持当前事务有效，
 *   直到 i_frame_done 到达或事务超时。
 * - i_frame_done 正常结束事务并释放接收；若与事务超时条件同拍，i_frame_done 优先。
 *
 * 关键时序：
 * - 从检测到首个 SOF 字节 55 后开始字节间超时监测；每个 i_rx_valid 重新计时。
 * - 字节间超时为 8N1 下 1.5 个字符时间，即 15 个波特位周期。
 * - 合法请求提交后的 busy 期间忽略所有 i_rx_valid，不接收或排队下一请求。
 * - Payload RAM 读口为同步读；工程约定 o_payload_rd_data 相对 i_payload_rd_addr 延迟 1clk。
 * - o_frame_valid 以及所有 *_error/*_timeout 输出均为 1clk pulse。
 *
 * 异常与恢复：
 * - reset：i_rst_n 在 i_clk 上升沿同步采样；低电平时回到等待 SOF，清除事务上下文和事件输出。
 * - rx timeout：未完成帧的字节间隔超限时丢弃当前帧，产生 o_rx_timeout，并重新等待 SOF。
 * - length error：LENGTH>MAX_PAYLOAD_LENGTH 时立即丢弃，产生 o_length_error，不写后续 Payload。
 * - CRC/地址错误：CRC 先判定；CRC 错只产生 o_crc_error，CRC 正确但地址不匹配才产生 o_addr_error；
 *   两种情况均不产生 o_frame_valid。
 * - transaction timeout：合法请求提交后长期未收到 i_frame_done 时，释放事务、清除上下文并产生
 *   o_transaction_timeout；Payload RAM 内容不作为事务完成后的有效数据继续使用。
 *
 * 使用约束：
 * - 当前架构只允许一个已提交事务在途；后级必须最终给出 i_frame_done，或依赖事务超时恢复。
 * - i_local_addr 应在当前帧接收和最终地址判定期间保持稳定。
 * - 接收错误只提供诊断脉冲，不代表存在可交给业务层处理的合法请求。
 *
 * 参考：
 * - COMMUNICATION_PROTOCOL.md：帧格式、字段含义和协议级错误处理规则。
 * - FPGA_COMM_ARCH.md：通信链路、模块边界和全局事务约束。
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
    wire [7:0] payload_ram_doa;

    assign payload_ram_we = (!request_busy) &&
                            (state == ST_PAYLOAD) && i_rx_valid;

    /* CRC 从 ADDR 开始累计，不包含 SOF 和接收到的 CRC 字段。 */
    crc16_modbus u_crc16_modbus (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),
        .i_init       (crc_init),
        .i_data_valid (crc_data_valid),
        .i_data       (crc_data),
        .o_crc        (crc_value)
    );

    /* A 口由解析器写入 Payload，B 口供后级业务模块同步读取。 */
    ip_ram_uart_rx u_payload_ram (
        .doa   (payload_ram_doa),
        .dia   (i_rx_byte),
        .addra (payload_wr_addr),
        .cea   (1'b1),
        .clka  (i_clk),
        .wea   (payload_ram_we),
        .rsta  (~i_rst_n),
        .ocea  (1'b1),
        .dob   (o_payload_rd_data),
        .dib   (8'h00),
        .addrb (i_payload_rd_addr),
        .ceb   (1'b1),
        .clkb  (i_clk),
        .web   (1'b0),
        .rstb  (~i_rst_n),
        .oceb  (1'b1)
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
                            /* 搜索帧头首字节。 */
                            if (i_rx_byte == 8'h55) begin
                                state <= ST_SOF_1;
                            end
                        end

                        ST_SOF_1: begin
                            /* 不支持重叠匹配：第二字节错误时直接回到 ST_SOF_0。 */
                            if (i_rx_byte == 8'hAA) begin
                                state    <= ST_ADDR;
                                crc_init <= 1'b1;
                            end else begin
                                state <= ST_SOF_0;
                            end
                        end

                        ST_ADDR: begin
                            /* 从 ADDR 开始将每个协议字节送入 CRC。 */
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
