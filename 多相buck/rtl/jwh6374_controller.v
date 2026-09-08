`timescale 1ns / 1ps
`include "jwh6374_common_defs.vh"

/*
**定位**：JWH6374 单次 PMBus 寄存器事务控制器。

本模块位于系统主状态机与 `i2c_master_core` 之间，将一次寄存器请求转换为
START / WRITE / READ / STOP Token。模块只负责单颗器件的一次访问，不负责：
TCA9548A 通道选择、64 颗器件轮询、EN 时序、重试策略和 BUS_CLEAR 恢复。

#### 1. 支持的操作 (`i_req_op`)
*   `3'd0`：Send Byte
*   `3'd1`：Write Byte
*   `3'd2`：Write Word，低字节先发送
*   `3'd3`：Read Byte
*   `3'd4`：Read Word，低字节先接收
*   `3'd5`：SMBus Alert Response，向ARA 0x0C读回告警器件地址

#### 2. 各操作的总线顺序
*   `Send Byte`：
    `START -> AddrW -> Command -> [PEC] -> STOP`
*   `Write Byte`：
    `START -> AddrW -> Command -> Data -> [PEC] -> STOP`
*   `Write Word`：
    `START -> AddrW -> Command -> DataLow -> DataHigh -> [PEC] -> STOP`
*   `Read Byte`：
    `START -> AddrW -> Command -> RESTART -> AddrR -> Data -> [PEC] -> STOP`
*   `Read Word`：
    `START -> AddrW -> Command -> RESTART -> AddrR -> DataLow -> DataHigh -> [PEC] -> STOP`
*   `Alert Response`：
    `START -> ARA AddrR(8'h19) -> DeviceAddress -> NACK -> STOP`，不使用PEC。
*   `AddrW={7-bit Address, 1'b0}`，`AddrR={7-bit Address, 1'b1}`。
*   方括号 `[PEC]` 表示仅在 `i_req_pec_en=1` 时发送或接收。
*   无 PEC 的读事务对最后一个 Data 回复 NACK；有 PEC 时对最后一个 Data 回复 ACK，
    再读取 PEC 并回复 NACK，最后发送 STOP。

#### 3. PAGE 处理
*   `i_req_page_valid=1` 时，先独立执行一次 `PAGE(00h)` Write Byte 事务并 STOP，
    成功后再执行目标寄存器事务。
*   `i_req_page_valid=0` 时，直接访问器件当前 PAGE。
*   PAGE 前置事务顺序：
    `START -> AddrW -> 8'h00 -> Page -> [PEC] -> STOP`

#### 4. PEC
*   `i_req_pec_en=1` 时，写事务自动追加 PEC，读事务自动读取并校验 PEC。
*   CRC 覆盖地址字节、Command 和数据；Read 事务的重复 START 后读地址也参与 CRC。

#### 5. 异常处理
*   任意发送字节收到 NACK：停止后续正常字节，发送 STOP 并返回分类错误。
*   PEC 不匹配：发送 STOP 后返回 PEC 错误。
*   底层 Timeout：立即进入冻结状态，等待顶层 `i_flush`；总线恢复由顶层负责。
*/

module jwh6374_controller (
    // 1. 系统与复位组
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_flush,

    // 2. 上行请求接口
    input  wire        i_req_valid,
    output reg         o_req_ready,
    input  wire [6:0]  i_req_dev_addr,       // 7 位 PMBus 地址，例如 7'h64
    input  wire        i_req_page_valid,     // 1：先写 PAGE；0：保持当前 PAGE
    input  wire [7:0]  i_req_page,
    input  wire [2:0]  i_req_op,
    input  wire [7:0]  i_req_command,
    input  wire [15:0] i_req_write_data,
    input  wire        i_req_pec_en,

    // 3. 上行响应接口
    output reg         o_resp_valid,
    input  wire        i_resp_ready,
    output reg  [15:0] o_resp_read_data,
    output reg         o_resp_error,
    output reg  [3:0]  o_resp_error_code,
    output wire        o_err_timeout,

    // 4. 下行 Token 接口：连接 i2c_master_core 或 i2c_client_mux
    output reg         o_i2c_cmd_valid,
    input  wire        i_i2c_cmd_ready,
    input  wire        i_i2c_cmd_done,
    output reg  [2:0]  o_i2c_cmd_type,
    output reg  [7:0]  o_i2c_tx_data,

    output reg         o_i2c_rx_ack_ctrl,    // 0=ACK，1=NACK
    output wire        o_i2c_rx_ready,
    input  wire [7:0]  i_i2c_rx_data,

    input  wire        i_i2c_err_nack,
    input  wire        i_i2c_err_timeout
);

    // =========================================================================
    // 常量与参数定义
    // =========================================================================

    // 主状态机
    localparam [4:0] ST_IDLE                = 5'd0,
                     ST_PREPARE_PAGE        = 5'd1,
                     ST_PREPARE_MAIN        = 5'd2,
                     ST_SEND_START          = 5'd3,
                     ST_WAIT_START_DONE     = 5'd4,
                     ST_SEND_TX_BYTE        = 5'd5,
                     ST_WAIT_TX_BYTE_DONE   = 5'd6,
                     ST_CRC_WAIT_WRITE      = 5'd7,
                     ST_SEND_WRITE_PEC      = 5'd8,
                     ST_WAIT_WRITE_PEC_DONE = 5'd9,
                     ST_SEND_RESTART        = 5'd10,
                     ST_WAIT_RESTART_DONE   = 5'd11,
                     ST_SEND_READ_ADDR      = 5'd12,
                     ST_WAIT_READ_ADDR_DONE = 5'd13,
                     ST_SEND_READ_BYTE      = 5'd14,
                     ST_WAIT_READ_BYTE_DONE = 5'd15,
                     ST_CRC_WAIT_READ       = 5'd16,
                     ST_SEND_READ_PEC       = 5'd17,
                     ST_WAIT_READ_PEC_DONE  = 5'd18,
                     ST_SEND_STOP           = 5'd19,
                     ST_WAIT_STOP_DONE      = 5'd20,
                     ST_RESPONSE            = 5'd21,
                     ST_FROZEN              = 5'd22;

    // =========================================================================
    // 请求锁存与事务描述寄存器
    // =========================================================================

    reg [4:0]  r_state;

    reg [6:0]  r_dev_addr;
    reg [7:0]  r_page;
    reg [2:0]  r_op;
    reg [7:0]  r_command;
    reg [15:0] r_write_data;
    reg        r_pec_en;
    reg        r_is_ara;

    // 当前子事务：1=PAGE 写入，0=目标寄存器访问
    reg        r_is_page_transaction;
    reg        r_is_read_transaction;

    // 发送缓冲：最长为 AddrW + Command + DataLow + DataHigh
    reg [7:0]  r_tx_byte0;
    reg [7:0]  r_tx_byte1;
    reg [7:0]  r_tx_byte2;
    reg [7:0]  r_tx_byte3;
    reg [2:0]  r_tx_length;
    reg [2:0]  r_tx_index;

    reg [1:0]  r_rx_length;
    reg [1:0]  r_rx_index;

    // 当前发送缓冲字节选择
    reg [7:0]  r_current_tx_byte;
    always @(*) begin
        case (r_tx_index)
            3'd0:    r_current_tx_byte = r_tx_byte0;
            3'd1:    r_current_tx_byte = r_tx_byte1;
            3'd2:    r_current_tx_byte = r_tx_byte2;
            3'd3:    r_current_tx_byte = r_tx_byte3;
            default: r_current_tx_byte = 8'h00;
        endcase
    end

    // =========================================================================
    // SMBus PEC CRC-8
    // =========================================================================

    reg        r_crc_clear;
    reg        r_crc_data_valid;
    reg [7:0]  r_crc_data;
    wire [7:0] w_crc;

    smbus_crc8 u_smbus_crc8 (
        .i_clk        (i_clk),
        .i_rst_n      (i_rst_n),
        .i_clear      (r_crc_clear),
        .i_data_valid (r_crc_data_valid),
        .i_data       (r_crc_data),
        .o_crc        (w_crc)
    );

    // =========================================================================
    // 静态接口
    // =========================================================================

    assign o_i2c_rx_ready = 1'b1;
    assign o_err_timeout  = i_i2c_err_timeout;

    // =========================================================================
    // 主状态机
    // =========================================================================

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state                  <= ST_IDLE;

            r_dev_addr               <= 7'd0;
            r_page                   <= 8'd0;
            r_op                     <= `JWH_OP_SEND_BYTE;
            r_command                <= 8'd0;
            r_write_data             <= 16'd0;
            r_pec_en                 <= 1'b0;
            r_is_ara                 <= 1'b0;

            r_is_page_transaction    <= 1'b0;
            r_is_read_transaction    <= 1'b0;
            r_tx_byte0               <= 8'd0;
            r_tx_byte1               <= 8'd0;
            r_tx_byte2               <= 8'd0;
            r_tx_byte3               <= 8'd0;
            r_tx_length              <= 3'd0;
            r_tx_index               <= 3'd0;
            r_rx_length              <= 2'd0;
            r_rx_index               <= 2'd0;

            r_crc_clear              <= 1'b0;
            r_crc_data_valid         <= 1'b0;
            r_crc_data               <= 8'd0;

            o_req_ready              <= 1'b0;
            o_resp_valid             <= 1'b0;
            o_resp_read_data         <= 16'd0;
            o_resp_error             <= 1'b0;
            o_resp_error_code        <= `JWH_ERR_NONE;

            o_i2c_cmd_valid          <= 1'b0;
            o_i2c_cmd_type           <= 3'd0;
            o_i2c_tx_data            <= 8'd0;
            o_i2c_rx_ack_ctrl        <= 1'b1;
        end else if (i_flush) begin
            // 顶层完成物理总线恢复时，同步清理本模块事务上下文
            r_state                  <= ST_IDLE;
            r_crc_clear              <= 1'b1;
            r_crc_data_valid         <= 1'b0;

            o_req_ready              <= 1'b0;
            o_resp_valid             <= 1'b0;
            o_resp_error             <= 1'b0;
            o_resp_error_code        <= `JWH_ERR_NONE;
            o_i2c_cmd_valid          <= 1'b0;
            o_i2c_rx_ack_ctrl        <= 1'b1;
        end else if (i_i2c_err_timeout) begin
            // 底层已经冻结；不再尝试 STOP，等待顶层 i_flush 和 BUS_CLEAR
            r_state                  <= ST_FROZEN;
            r_crc_clear              <= 1'b0;
            r_crc_data_valid         <= 1'b0;

            o_req_ready              <= 1'b0;
            o_resp_valid             <= 1'b0;
            o_resp_error             <= 1'b1;
            o_resp_error_code        <= `JWH_ERR_TIMEOUT;
            o_i2c_cmd_valid          <= 1'b0;
        end else begin
            // CRC 控制信号默认为单拍脉冲
            r_crc_clear      <= 1'b0;
            r_crc_data_valid <= 1'b0;

            case (r_state)
                // -------------------------------------------------------------
                // 空闲：锁存一笔完整请求
                // -------------------------------------------------------------
                ST_IDLE: begin
                    o_req_ready       <= 1'b1;
                    o_resp_valid      <= 1'b0;
                    o_i2c_cmd_valid   <= 1'b0;
                    o_resp_error      <= 1'b0;
                    o_resp_error_code <= `JWH_ERR_NONE;

                    if (i_req_valid && o_req_ready) begin
                        o_req_ready       <= 1'b0;
                        o_resp_read_data  <= 16'd0;

                        r_dev_addr        <= i_req_dev_addr;
                        r_page            <= i_req_page;
                        r_op              <= i_req_op;
                        r_command         <= i_req_command;
                        r_write_data      <= i_req_write_data;
                        r_pec_en          <= (i_req_op == `JWH_OP_ARA) ?
                                             1'b0 : i_req_pec_en;
                        r_is_ara          <= (i_req_op == `JWH_OP_ARA);

                        if (i_req_op > `JWH_OP_ARA) begin
                            o_resp_error      <= 1'b1;
                            o_resp_error_code <= `JWH_ERR_INVALID_OP;
                            r_state           <= ST_RESPONSE;
                        end else if (i_req_page_valid) begin
                            r_state <= ST_PREPARE_PAGE;
                        end else begin
                            r_state <= ST_PREPARE_MAIN;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 准备 PAGE(00h) Write Byte 独立事务
                // -------------------------------------------------------------
                ST_PREPARE_PAGE: begin
                    r_is_page_transaction <= 1'b1;
                    r_is_read_transaction <= 1'b0;

                    r_tx_byte0            <= {r_dev_addr, 1'b0};
                    r_tx_byte1            <= 8'h00;
                    r_tx_byte2            <= r_page;
                    r_tx_byte3            <= 8'h00;
                    r_tx_length           <= 3'd3;
                    r_tx_index            <= 3'd0;
                    r_rx_length           <= 2'd0;
                    r_rx_index            <= 2'd0;

                    r_crc_clear           <= 1'b1;
                    r_state               <= ST_SEND_START;
                end

                // -------------------------------------------------------------
                // 准备目标寄存器事务
                // -------------------------------------------------------------
                ST_PREPARE_MAIN: begin
                    r_is_page_transaction <= 1'b0;
                    r_tx_byte0            <= {r_dev_addr, 1'b0};
                    r_tx_byte1            <= r_command;
                    r_tx_byte2            <= r_write_data[7:0];
                    r_tx_byte3            <= r_write_data[15:8];
                    r_tx_index            <= 3'd0;
                    r_rx_index            <= 2'd0;

                    case (r_op)
                        `JWH_OP_SEND_BYTE: begin
                            r_is_read_transaction <= 1'b0;
                            r_tx_length           <= 3'd2;
                            r_rx_length           <= 2'd0;
                        end

                        `JWH_OP_WRITE_BYTE: begin
                            r_is_read_transaction <= 1'b0;
                            r_tx_length           <= 3'd3;
                            r_rx_length           <= 2'd0;
                        end

                        `JWH_OP_WRITE_WORD: begin
                            r_is_read_transaction <= 1'b0;
                            r_tx_length           <= 3'd4;
                            r_rx_length           <= 2'd0;
                        end

                        `JWH_OP_READ_BYTE: begin
                            r_is_read_transaction <= 1'b1;
                            r_tx_length           <= 3'd2;
                            r_rx_length           <= 2'd1;
                        end

                        `JWH_OP_READ_WORD: begin
                            r_is_read_transaction <= 1'b1;
                            r_tx_length           <= 3'd2;
                            r_rx_length           <= 2'd2;
                        end

                        `JWH_OP_ARA: begin
                            // ARA是Modified Receive Byte：0x19后直接读取地址字节。
                            r_is_read_transaction <= 1'b1;
                            r_tx_byte0            <= 8'h19;
                            r_tx_length           <= 3'd1;
                            r_rx_length           <= 2'd1;
                        end

                        default: begin
                            r_is_read_transaction <= 1'b0;
                            r_tx_length           <= 3'd0;
                            r_rx_length           <= 2'd0;
                        end
                    endcase

                    r_crc_clear <= 1'b1;
                    r_state     <= ST_SEND_START;
                end

                // -------------------------------------------------------------
                // START
                // -------------------------------------------------------------
                ST_SEND_START: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_START;

                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_START_DONE;
                    end
                end

                ST_WAIT_START_DONE: begin
                    if (i_i2c_cmd_done) begin
                        r_state <= ST_SEND_TX_BYTE;
                    end
                end

                // -------------------------------------------------------------
                // 依次发送 AddrW / Command / Data
                // -------------------------------------------------------------
                ST_SEND_TX_BYTE: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_WRITE;
                    o_i2c_tx_data   <= r_current_tx_byte;

                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_TX_BYTE_DONE;
                    end
                end

                ST_WAIT_TX_BYTE_DONE: begin
                    if (i_i2c_cmd_done) begin
                        if (i_i2c_err_nack) begin
                            if (r_tx_index == 3'd0) begin
                                o_resp_error_code <= `JWH_ERR_NACK_ADDR;
                            end else if (r_tx_index == 3'd1) begin
                                o_resp_error_code <= `JWH_ERR_NACK_CMD;
                            end else begin
                                o_resp_error_code <= `JWH_ERR_NACK_DATA;
                            end

                            o_resp_error <= 1'b1;
                            r_state      <= ST_SEND_STOP;
                        end else begin
                            // 地址、Command 和数据均参与 PEC
                            r_crc_data       <= r_current_tx_byte;
                            r_crc_data_valid <= 1'b1;

                            if (r_tx_index + 1'b1 < r_tx_length) begin
                                r_tx_index <= r_tx_index + 1'b1;
                                r_state    <= ST_SEND_TX_BYTE;
                            end else if (r_is_ara) begin
                                // ARA的0x19本身已经是读地址，不需要Repeated START。
                                r_rx_index <= 2'd0;
                                r_state    <= ST_SEND_READ_BYTE;
                            end else if (r_is_read_transaction) begin
                                r_state <= ST_SEND_RESTART;
                            end else if (r_pec_en) begin
                                r_state <= ST_CRC_WAIT_WRITE;
                            end else begin
                                r_state <= ST_SEND_STOP;
                            end
                        end
                    end
                end

                // 最后一个数据字节提交给 CRC 后等待一拍，避免读取旧 CRC
                ST_CRC_WAIT_WRITE: begin
                    r_state <= ST_SEND_WRITE_PEC;
                end

                ST_SEND_WRITE_PEC: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_WRITE;
                    o_i2c_tx_data   <= w_crc;

                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_WRITE_PEC_DONE;
                    end
                end

                ST_WAIT_WRITE_PEC_DONE: begin
                    if (i_i2c_cmd_done) begin
                        if (i_i2c_err_nack) begin
                            o_resp_error      <= 1'b1;
                            o_resp_error_code <= `JWH_ERR_NACK_DATA;
                        end
                        r_state <= ST_SEND_STOP;
                    end
                end

                // -------------------------------------------------------------
                // Read Byte/Word：Repeated START + AddrR
                // -------------------------------------------------------------
                ST_SEND_RESTART: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_START;

                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_RESTART_DONE;
                    end
                end

                ST_WAIT_RESTART_DONE: begin
                    if (i_i2c_cmd_done) begin
                        r_state <= ST_SEND_READ_ADDR;
                    end
                end

                ST_SEND_READ_ADDR: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_WRITE;
                    o_i2c_tx_data   <= {r_dev_addr, 1'b1};

                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_READ_ADDR_DONE;
                    end
                end

                ST_WAIT_READ_ADDR_DONE: begin
                    if (i_i2c_cmd_done) begin
                        if (i_i2c_err_nack) begin
                            o_resp_error      <= 1'b1;
                            o_resp_error_code <= `JWH_ERR_NACK_ADDR;
                            r_state           <= ST_SEND_STOP;
                        end else begin
                            // 重复 START 后的读地址也参与同一笔 Read 事务 PEC
                            r_crc_data       <= {r_dev_addr, 1'b1};
                            r_crc_data_valid <= 1'b1;
                            r_rx_index       <= 2'd0;
                            r_state          <= ST_SEND_READ_BYTE;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 接收数据：中间字节 ACK，最后数据字节按是否还有 PEC 决定 ACK/NACK
                // -------------------------------------------------------------
                ST_SEND_READ_BYTE: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_READ;

                    if (r_rx_index + 1'b1 < r_rx_length) begin
                        o_i2c_rx_ack_ctrl <= 1'b0;
                    end else if (r_pec_en) begin
                        o_i2c_rx_ack_ctrl <= 1'b0;
                    end else begin
                        o_i2c_rx_ack_ctrl <= 1'b1;
                    end

                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_READ_BYTE_DONE;
                    end
                end

                ST_WAIT_READ_BYTE_DONE: begin
                    if (i_i2c_cmd_done) begin
                        if (r_rx_index == 2'd0) begin
                            o_resp_read_data[7:0] <= i_i2c_rx_data;
                        end else begin
                            o_resp_read_data[15:8] <= i_i2c_rx_data;
                        end

                        r_crc_data       <= i_i2c_rx_data;
                        r_crc_data_valid <= 1'b1;

                        if (r_rx_index + 1'b1 < r_rx_length) begin
                            r_rx_index <= r_rx_index + 1'b1;
                            r_state    <= ST_SEND_READ_BYTE;
                        end else if (r_pec_en) begin
                            r_state <= ST_CRC_WAIT_READ;
                        end else begin
                            r_state <= ST_SEND_STOP;
                        end
                    end
                end

                // 最后一个数据字节纳入 CRC 后再读取从机返回的 PEC
                ST_CRC_WAIT_READ: begin
                    r_state <= ST_SEND_READ_PEC;
                end

                ST_SEND_READ_PEC: begin
                    o_i2c_cmd_valid   <= 1'b1;
                    o_i2c_cmd_type    <= `I2C_CMD_READ;
                    o_i2c_rx_ack_ctrl <= 1'b1;

                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_READ_PEC_DONE;
                    end
                end

                ST_WAIT_READ_PEC_DONE: begin
                    if (i_i2c_cmd_done) begin
                        if (i_i2c_rx_data != w_crc) begin
                            o_resp_error      <= 1'b1;
                            o_resp_error_code <= `JWH_ERR_PEC;
                        end
                        r_state <= ST_SEND_STOP;
                    end
                end

                // -------------------------------------------------------------
                // 所有正常结束与 NACK 异常都必须 STOP 收尾
                // -------------------------------------------------------------
                ST_SEND_STOP: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_STOP;

                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_STOP_DONE;
                    end
                end

                ST_WAIT_STOP_DONE: begin
                    if (i_i2c_cmd_done) begin
                        o_i2c_rx_ack_ctrl <= 1'b1;

                        if (r_is_page_transaction &&
                            (o_resp_error_code == `JWH_ERR_NONE)) begin
                            r_state <= ST_PREPARE_MAIN;
                        end else begin
                            r_state <= ST_RESPONSE;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 响应：保持到上层 ready 握手
                // -------------------------------------------------------------
                ST_RESPONSE: begin
                    o_resp_valid <= 1'b1;

                    if (o_resp_valid && i_resp_ready) begin
                        o_resp_valid <= 1'b0;
                        r_state      <= ST_IDLE;
                    end
                end

                // -------------------------------------------------------------
                // Timeout 后冻结，等待顶层完成物理恢复并给 i_flush
                // -------------------------------------------------------------
                ST_FROZEN: begin
                    o_req_ready       <= 1'b0;
                    o_resp_valid      <= 1'b0;
                    o_i2c_cmd_valid   <= 1'b0;
                    o_resp_error      <= 1'b1;
                    o_resp_error_code <= `JWH_ERR_TIMEOUT;
                end

                default: begin
                    r_state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
