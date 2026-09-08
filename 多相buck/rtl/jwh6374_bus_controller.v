`timescale 1ns / 1ps
`include "jwh6374_common_defs.vh"

/*
**定位**：一条 JWH6374 物理总线的完整控制器。

本模块内部包含一颗 TCA9548A 控制器、一颗 JWH6374 PMBus 事务控制器和一颗
`i2c_master_core`。上层只提交“通道 + JWH 地址 + 目标 PAGE + PMBus 操作”，
无需控制 TCA 通道、判断是否需要发送 PAGE，也无需仲裁底层 I2C Token。

`P_TCA_ENABLE=1` 保持原有 TCA 路由方式；`P_TCA_ENABLE=0` 用于单器件直连，
固定物理通道为 0 并直接进入 JWH 事务。直连模式下非零通道请求立即返回
`JWH_BUS_ERR_INVALID_CHANNEL`，不会在物理 I2C 总线上发送任何字节。

#### PAGE 缓存
* 本模块缓存最近一次确认成功的“通道 + 地址 + PAGE”；
* 缓存无效或三个字段任一个变化时，先令 JWH controller 写 PAGE；
* PAGE 与目标操作全部成功后才更新缓存；中途失败则缓存失效；
* ARA 不使用 PAGE，也不改变 PAGE 缓存；
* Reset、Clear、Timeout、BUS_CLEAR 或 TCA 切换失败均使缓存失效。

#### 正常访问顺序
* 当前通道无效或与目标通道不同：
  `TCA START -> AddrW -> ChannelMask -> STOP`
  `JWH START -> AddrW -> Command/Data/PEC -> [RESTART/READ] -> STOP`
* 当前通道已经选中：
  直接执行 JWH PMBus 事务。

#### Timeout 与 BUS_CLEAR
* 任意底层 Timeout 后，本模块放弃当前事务；
* 同时 flush TCA、JWH 与 I2C 三个状态机；
* 恢复状态机独占 Token 接口，发送一次 `CMD_BUS_CLEAR`；
* BUS_CLEAR 成功后使通道缓存失效，并返回 `JWH_BUS_ERR_TIMEOUT_RECOVERED`；
* BUS_CLEAR 再次 Timeout，或命令完成后SCL/SDA仍未同时为高时，返回一次
  `JWH_BUS_ERR_CLEAR_FAILED`，并在内部锁定总线；
* 总线锁定后不再访问物理总线，但仍接收逻辑请求并立即返回相同错误码，
  直到上层给出 `i_clear`；
* 被中断的 PMBus 事务不会自动重试，由 system_controller/上位机决定。

PEC 是本总线的固定策略，由 `P_PEC_ENABLE` 参数决定。TCA9548A 事务不使用 PEC。
*/

module jwh6374_bus_controller #(
    parameter integer P_SYS_CLK_FREQ       = 100_000_000,
    parameter integer P_I2C_BAUD_RATE      = 400_000,
    parameter integer P_I2C_TIMEOUT_MS     = 35,
    parameter [6:0]   P_TCA_ADDR           = 7'h70,
    parameter [31:0]  P_TCA_DEAD_CYCLES    = 32'd500,
    parameter         P_PEC_ENABLE         = 1'b1,
    parameter         P_TCA_ENABLE         = 1'b1
)(
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_clear,

    // 上行高层请求
    input  wire        i_req_valid,
    output reg         o_req_ready,
    input  wire [2:0]  i_req_channel,
    input  wire [6:0]  i_req_dev_addr,
    input  wire [7:0]  i_req_page,
    input  wire [2:0]  i_req_op,
    input  wire [7:0]  i_req_command,
    input  wire [15:0] i_req_write_data,

    output reg         o_resp_valid,
    input  wire        i_resp_ready,
    output reg [15:0]  o_resp_read_data,
    output reg         o_resp_error,
    output reg [4:0]   o_resp_error_code,

    output reg [3:0]   o_debug_state,

    // 开漏物理接口
    input  wire        i_scl_i,
    output wire        o_scl_o,
    output wire        o_scl_t,
    input  wire        i_sda_i,
    output wire        o_sda_o,
    output wire        o_sda_t
);

    localparam [2:0] OWNER_NONE     = 3'd0,
                     OWNER_TCA      = 3'd1,
                     OWNER_JWH      = 3'd2,
                     OWNER_RECOVERY = 3'd3;

    localparam [3:0] ST_IDLE           = 4'd0,
                     ST_TCA_REQUEST    = 4'd1,
                     ST_TCA_RESPONSE   = 4'd2,
                     ST_JWH_REQUEST    = 4'd3,
                     ST_JWH_RESPONSE   = 4'd4,
                     ST_FLUSH          = 4'd5,
                     ST_RECOVERY_WAIT  = 4'd6,
                     ST_BUS_CLEAR_SEND = 4'd7,
                     ST_BUS_CLEAR_WAIT = 4'd8,
                     ST_RESPONSE       = 4'd9;

    reg [3:0] r_state;
    reg [2:0] r_owner;
    // 恢复过程和总线健康状态只属于本模块，不向业务层暴露。
    reg       r_recovery_active;
    reg       r_bus_ok;
    reg [2:0] r_active_channel;
    reg       r_active_channel_valid;

    reg [2:0]  r_channel;
    reg [6:0]  r_dev_addr;
    // 本次请求是否需要先执行 PAGE(00h) Write Byte。
    reg        r_request_needs_page;
    reg [7:0]  r_page;
    reg [2:0]  r_op;
    reg [7:0]  r_command;
    reg [15:0] r_write_data;

    // 单项 PAGE 缓存。通道是物理设备身份的一部分，因为不同 TCA
    // 支路可以使用相同的 JWH 地址。
    reg       r_page_cache_valid;
    reg [2:0] r_page_cache_channel;
    reg [6:0] r_page_cache_dev_addr;
    reg [7:0] r_page_cache_page;

    wire [2:0] w_effective_req_channel =
        P_TCA_ENABLE ? i_req_channel : 3'd0;

    reg r_local_flush;
    reg r_recovery_cmd_valid;

    // TCA controller 上行
    reg        r_tca_cmd_valid;
    wire       w_tca_cmd_ready;
    wire       w_tca_resp_valid;
    wire       w_tca_resp_error;

    // JWH controller 上行
    reg         r_jwh_req_valid;
    wire        w_jwh_req_ready;
    wire        w_jwh_resp_valid;
    wire [15:0] w_jwh_resp_read_data;
    wire        w_jwh_resp_error;
    wire [3:0]  w_jwh_resp_error_code;

    // TCA Token
    wire       w_tca_i2c_cmd_valid;
    wire [2:0] w_tca_i2c_cmd_type;
    wire [7:0] w_tca_i2c_tx_data;
    wire       w_tca_i2c_rx_ack_ctrl;
    wire       w_tca_i2c_rx_ready;

    // JWH Token
    wire       w_jwh_i2c_cmd_valid;
    wire [2:0] w_jwh_i2c_cmd_type;
    wire [7:0] w_jwh_i2c_tx_data;
    wire       w_jwh_i2c_rx_ack_ctrl;
    wire       w_jwh_i2c_rx_ready;

    // 共享 I2C core
    reg        r_i2c_cmd_valid;
    reg [2:0]  r_i2c_cmd_type;
    reg [7:0]  r_i2c_tx_data;
    reg        r_i2c_rx_ack_ctrl;
    reg        r_i2c_rx_ready;
    wire       w_i2c_cmd_ready;
    wire       w_i2c_cmd_done;
    wire       w_i2c_bus_idle;
    wire       w_i2c_rx_valid;
    wire [7:0] w_i2c_rx_data;
    wire       w_i2c_err_nack;
    wire       w_i2c_err_timeout;

    wire w_tca_cmd_ready_selected =
        (r_owner == OWNER_TCA) ? w_i2c_cmd_ready : 1'b0;
    wire w_tca_cmd_done_selected =
        (r_owner == OWNER_TCA) ? w_i2c_cmd_done : 1'b0;
    wire w_jwh_cmd_ready_selected =
        (r_owner == OWNER_JWH) ? w_i2c_cmd_ready : 1'b0;
    wire w_jwh_cmd_done_selected =
        (r_owner == OWNER_JWH) ? w_i2c_cmd_done : 1'b0;

    // Token 静态仲裁。恢复状态拥有最高且独占的 Token 所有权。
    always @(*) begin
        r_i2c_cmd_valid   = 1'b0;
        r_i2c_cmd_type    = 3'd0;
        r_i2c_tx_data     = 8'd0;
        r_i2c_rx_ack_ctrl = 1'b1;
        r_i2c_rx_ready    = 1'b1;

        case (r_owner)
            OWNER_TCA: begin
                r_i2c_cmd_valid   = w_tca_i2c_cmd_valid;
                r_i2c_cmd_type    = w_tca_i2c_cmd_type;
                r_i2c_tx_data     = w_tca_i2c_tx_data;
                r_i2c_rx_ack_ctrl = w_tca_i2c_rx_ack_ctrl;
                r_i2c_rx_ready    = w_tca_i2c_rx_ready;
            end
            OWNER_JWH: begin
                r_i2c_cmd_valid   = w_jwh_i2c_cmd_valid;
                r_i2c_cmd_type    = w_jwh_i2c_cmd_type;
                r_i2c_tx_data     = w_jwh_i2c_tx_data;
                r_i2c_rx_ack_ctrl = w_jwh_i2c_rx_ack_ctrl;
                r_i2c_rx_ready    = w_jwh_i2c_rx_ready;
            end
            OWNER_RECOVERY: begin
                r_i2c_cmd_valid = r_recovery_cmd_valid;
                r_i2c_cmd_type  = `I2C_CMD_BUS_CLEAR;
            end
            default: begin
            end
        endcase
    end

    generate
        if (P_TCA_ENABLE) begin : g_tca_enabled
            tca9548a_controller #(
                .P_TCA_ADDR         (P_TCA_ADDR),
                .P_DEAD_TIME_CYCLES (P_TCA_DEAD_CYCLES)
            ) u_tca9548a_controller (
                .i_clk             (i_clk),
                .i_rst_n           (i_rst_n),
                .i_flush           (r_local_flush),
                .i_cmd_valid       (r_tca_cmd_valid),
                .o_cmd_ready       (w_tca_cmd_ready),
                .i_cmd_ch_sel      (r_channel),
                .i_cmd_en          (1'b1),
                .o_resp_valid      (w_tca_resp_valid),
                .i_resp_ready      (1'b1),
                .o_resp_error      (w_tca_resp_error),
                .o_err_timeout     (),
                .o_i2c_cmd_valid   (w_tca_i2c_cmd_valid),
                .i_i2c_cmd_ready   (w_tca_cmd_ready_selected),
                .i_i2c_cmd_done    (w_tca_cmd_done_selected),
                .o_i2c_cmd_type    (w_tca_i2c_cmd_type),
                .o_i2c_tx_data     (w_tca_i2c_tx_data),
                .o_i2c_flush       (),
                .o_i2c_rx_ack_ctrl (w_tca_i2c_rx_ack_ctrl),
                .o_i2c_rx_ready    (w_tca_i2c_rx_ready),
                .i_i2c_err_nack    (w_i2c_err_nack),
                .i_i2c_err_timeout (w_i2c_err_timeout)
            );
        end else begin : g_tca_disabled
            // Keep the shared-token mux fully defined while removing the TCA
            // state machine and all of its sequential resources from the
            // direct-mode netlist.
            assign w_tca_cmd_ready       = 1'b0;
            assign w_tca_resp_valid      = 1'b0;
            assign w_tca_resp_error      = 1'b0;
            assign w_tca_i2c_cmd_valid   = 1'b0;
            assign w_tca_i2c_cmd_type    = 3'd0;
            assign w_tca_i2c_tx_data     = 8'd0;
            assign w_tca_i2c_rx_ack_ctrl = 1'b1;
            assign w_tca_i2c_rx_ready    = 1'b1;
        end
    endgenerate

    jwh6374_controller u_jwh6374_controller (
        .i_clk                 (i_clk),
        .i_rst_n               (i_rst_n),
        .i_flush               (r_local_flush),
        .i_req_valid           (r_jwh_req_valid),
        .o_req_ready           (w_jwh_req_ready),
        .i_req_dev_addr        (r_dev_addr),
        .i_req_page_valid      (r_request_needs_page),
        .i_req_page            (r_page),
        .i_req_op              (r_op),
        .i_req_command         (r_command),
        .i_req_write_data      (r_write_data),
        .i_req_pec_en          (P_PEC_ENABLE),
        .o_resp_valid          (w_jwh_resp_valid),
        .i_resp_ready          (1'b1),
        .o_resp_read_data      (w_jwh_resp_read_data),
        .o_resp_error          (w_jwh_resp_error),
        .o_resp_error_code     (w_jwh_resp_error_code),
        .o_err_timeout         (),
        .o_i2c_cmd_valid       (w_jwh_i2c_cmd_valid),
        .i_i2c_cmd_ready       (w_jwh_cmd_ready_selected),
        .i_i2c_cmd_done        (w_jwh_cmd_done_selected),
        .o_i2c_cmd_type        (w_jwh_i2c_cmd_type),
        .o_i2c_tx_data         (w_jwh_i2c_tx_data),
        .o_i2c_rx_ack_ctrl     (w_jwh_i2c_rx_ack_ctrl),
        .o_i2c_rx_ready        (w_jwh_i2c_rx_ready),
        .i_i2c_rx_data         (w_i2c_rx_data),
        .i_i2c_err_nack        (w_i2c_err_nack),
        .i_i2c_err_timeout     (w_i2c_err_timeout)
    );

    i2c_master_core #(
        .SYS_CLK_FREQ  (P_SYS_CLK_FREQ),
        .I2C_BAUD_RATE (P_I2C_BAUD_RATE),
        .TIMEOUT_MS    (P_I2C_TIMEOUT_MS)
    ) u_i2c_master_core (
        .i_clk         (i_clk),
        .i_rst_n       (i_rst_n),
        .i_cmd_valid   (r_i2c_cmd_valid),
        .o_cmd_ready   (w_i2c_cmd_ready),
        .o_cmd_done    (w_i2c_cmd_done),
        .i_cmd_type    (r_i2c_cmd_type),
        .i_tx_data     (r_i2c_tx_data),
        .i_rx_ack_ctrl (r_i2c_rx_ack_ctrl),
        .i_rx_ready    (r_i2c_rx_ready),
        .o_rx_valid    (w_i2c_rx_valid),
        .o_rx_data     (w_i2c_rx_data),
        .i_flush       (r_local_flush),
        .o_err_nack    (w_i2c_err_nack),
        .o_err_timeout (w_i2c_err_timeout),
        .o_bus_idle    (w_i2c_bus_idle),
        .i_scl_i       (i_scl_i),
        .o_scl_o       (o_scl_o),
        .o_scl_t       (o_scl_t),
        .i_sda_i       (i_sda_i),
        .o_sda_o       (o_sda_o),
        .o_sda_t       (o_sda_t)
    );

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state                 <= ST_IDLE;
            r_owner                 <= OWNER_NONE;
            r_active_channel        <= 3'd0;
            r_active_channel_valid  <= 1'b0;
            r_channel               <= 3'd0;
            r_dev_addr              <= 7'd0;
            r_request_needs_page    <= 1'b0;
            r_page                  <= 8'd0;
            r_op                    <= 3'd0;
            r_command               <= 8'd0;
            r_write_data            <= 16'd0;
            r_page_cache_valid      <= 1'b0;
            r_page_cache_channel    <= 3'd0;
            r_page_cache_dev_addr   <= 7'd0;
            r_page_cache_page       <= 8'd0;
            r_local_flush           <= 1'b0;
            r_recovery_cmd_valid    <= 1'b0;
            r_tca_cmd_valid         <= 1'b0;
            r_jwh_req_valid         <= 1'b0;
            o_req_ready             <= 1'b0;
            o_resp_valid            <= 1'b0;
            o_resp_read_data        <= 16'd0;
            o_resp_error            <= 1'b0;
            o_resp_error_code       <= `JWH_BUS_ERR_NONE;
            r_recovery_active       <= 1'b0;
            r_bus_ok                <= 1'b1;
            o_debug_state           <= ST_IDLE;
        end else if (i_clear) begin
            r_state                 <= ST_IDLE;
            r_owner                 <= OWNER_NONE;
            r_active_channel_valid  <= 1'b0;
            r_request_needs_page    <= 1'b0;
            r_page_cache_valid      <= 1'b0;
            r_local_flush           <= 1'b1;
            r_recovery_cmd_valid    <= 1'b0;
            r_tca_cmd_valid         <= 1'b0;
            r_jwh_req_valid         <= 1'b0;
            o_req_ready             <= 1'b0;
            o_resp_valid            <= 1'b0;
            o_resp_error            <= 1'b0;
            o_resp_error_code       <= `JWH_BUS_ERR_NONE;
            r_recovery_active       <= 1'b0;
            r_bus_ok                <= 1'b1;
            o_debug_state           <= ST_IDLE;
        end else begin
            r_local_flush <= 1'b0;
            o_debug_state <= r_state;

            // 这里只捕获普通事务的第一次Timeout。恢复期间的Timeout由
            // ST_BUS_CLEAR_WAIT处理，避免再次启动flush + BUS_CLEAR。
            if (w_i2c_err_timeout &&
                !r_recovery_active && r_bus_ok) begin
                r_active_channel_valid <= 1'b0;
                // Timeout 时无法判断 PAGE 字节是否已经被目标器件接受。
                r_page_cache_valid     <= 1'b0;
                r_tca_cmd_valid        <= 1'b0;
                r_jwh_req_valid        <= 1'b0;
                r_recovery_cmd_valid   <= 1'b0;
                r_owner                <= OWNER_NONE;
                o_req_ready            <= 1'b0;
                r_local_flush          <= 1'b1;
                r_recovery_active      <= 1'b1;
                r_state                <= ST_FLUSH;
            end else begin
                case (r_state)
                    ST_IDLE: begin
                        r_owner          <= OWNER_NONE;
                        o_req_ready      <= 1'b1;
                        o_resp_valid     <= 1'b0;
                        o_resp_error     <= 1'b0;
                        o_resp_error_code<= `JWH_BUS_ERR_NONE;
                        if (i_req_valid && o_req_ready) begin
                            o_req_ready  <= 1'b0;
                            // 恢复失败后只返回统一错误，不再驱动物理总线。
                            if (!r_bus_ok) begin
                                o_resp_read_data  <= 16'd0;
                                o_resp_error      <= 1'b1;
                                o_resp_error_code <=
                                    `JWH_BUS_ERR_CLEAR_FAILED;
                                r_state           <= ST_RESPONSE;
                            end else if (!P_TCA_ENABLE &&
                                         (i_req_channel != 3'd0)) begin
                                // 直连模式只有一个物理目标。拒绝非零通道，且不
                                // 进入任何底层状态，保证不会误发 TCA 地址。
                                o_resp_read_data  <= 16'd0;
                                o_resp_error      <= 1'b1;
                                o_resp_error_code <=
                                    `JWH_BUS_ERR_INVALID_CHANNEL;
                                r_state           <= ST_RESPONSE;
                            end else begin
                                r_channel    <= w_effective_req_channel;
                                r_dev_addr   <= i_req_dev_addr;
                                r_page       <= i_req_page;
                                // ARA 是 Modified Receive Byte，不属于任何 PAGE。
                                // 普通请求仅在物理目标或PAGE变化时重发PAGE。
                                r_request_needs_page <=
                                    (i_req_op != `JWH_OP_ARA) &&
                                    (!r_page_cache_valid ||
                                     (r_page_cache_channel !=
                                      w_effective_req_channel) ||
                                     (r_page_cache_dev_addr != i_req_dev_addr) ||
                                     (r_page_cache_page != i_req_page));
                                r_op         <= i_req_op;
                                r_command    <= i_req_command;
                                r_write_data <= i_req_write_data;
                                if (!P_TCA_ENABLE ||
                                    (r_active_channel_valid &&
                                     (r_active_channel ==
                                      w_effective_req_channel))) begin
                                    r_owner <= OWNER_JWH;
                                    r_state <= ST_JWH_REQUEST;
                                end else begin
                                    r_owner <= OWNER_TCA;
                                    r_state <= ST_TCA_REQUEST;
                                end
                            end
                        end
                    end

                    ST_TCA_REQUEST: begin
                        r_tca_cmd_valid <= 1'b1;
                        if (r_tca_cmd_valid && w_tca_cmd_ready) begin
                            r_tca_cmd_valid <= 1'b0;
                            r_state         <= ST_TCA_RESPONSE;
                        end
                    end

                    ST_TCA_RESPONSE: begin
                        if (w_tca_resp_valid) begin
                            if (w_tca_resp_error) begin
                                r_active_channel_valid <= 1'b0;
                                // TCA 状态不确定，保守丢弃 PAGE 缓存。
                                r_page_cache_valid     <= 1'b0;
                                o_resp_error           <= 1'b1;
                                o_resp_error_code      <= `JWH_BUS_ERR_TCA;
                                r_owner                 <= OWNER_NONE;
                                r_state                 <= ST_RESPONSE;
                            end else begin
                                r_active_channel       <= r_channel;
                                r_active_channel_valid <= 1'b1;
                                r_owner                <= OWNER_JWH;
                                r_state                <= ST_JWH_REQUEST;
                            end
                        end
                    end

                    ST_JWH_REQUEST: begin
                        r_jwh_req_valid <= 1'b1;
                        if (r_jwh_req_valid && w_jwh_req_ready) begin
                            r_jwh_req_valid <= 1'b0;
                            r_state         <= ST_JWH_RESPONSE;
                        end
                    end

                    ST_JWH_RESPONSE: begin
                        if (w_jwh_resp_valid) begin
                            o_resp_read_data  <= w_jwh_resp_read_data;
                            o_resp_error      <= w_jwh_resp_error;
                            o_resp_error_code <= {1'b0,
                                                  w_jwh_resp_error_code};
                            // PAGE 与主操作合并为一次上层请求。只有整笔成功，
                            // 才能确认缓存与器件一致；任何失败都必须失效，
                            // 避免“PAGE 已成功、主操作失败”留下错误旧缓存。
                            if (r_request_needs_page) begin
                                if (w_jwh_resp_error) begin
                                    r_page_cache_valid <= 1'b0;
                                end else begin
                                    r_page_cache_valid    <= 1'b1;
                                    r_page_cache_channel  <= r_channel;
                                    r_page_cache_dev_addr <= r_dev_addr;
                                    r_page_cache_page     <= r_page;
                                end
                            end
                            r_owner           <= OWNER_NONE;
                            r_state           <= ST_RESPONSE;
                        end
                    end

                    ST_FLUSH: begin
                        // 前一拍已经flush；再留一拍让三个子状态机稳定回到IDLE。
                        r_local_flush <= 1'b1;
                        r_state       <= ST_RECOVERY_WAIT;
                    end

                    ST_RECOVERY_WAIT: begin
                        r_owner <= OWNER_RECOVERY;
                        r_state <= ST_BUS_CLEAR_SEND;
                    end

                    ST_BUS_CLEAR_SEND: begin
                        r_recovery_cmd_valid <= 1'b1;
                        if (r_recovery_cmd_valid && w_i2c_cmd_ready) begin
                            r_recovery_cmd_valid <= 1'b0;
                            r_state              <= ST_BUS_CLEAR_WAIT;
                        end
                    end

                    ST_BUS_CLEAR_WAIT: begin
                        // BUS_CLEAR过程中再次Timeout，一般表示SCL持续卡低。
                        if (w_i2c_err_timeout) begin
                            r_local_flush           <= 1'b1;
                            r_owner                 <= OWNER_NONE;
                            r_active_channel_valid  <= 1'b0;
                            r_page_cache_valid      <= 1'b0;
                            r_recovery_active       <= 1'b0;
                            r_bus_ok                <= 1'b0;
                            o_resp_error            <= 1'b1;
                            o_resp_error_code       <=
                                `JWH_BUS_ERR_CLEAR_FAILED;
                            r_state                 <= ST_RESPONSE;
                        end else if (w_i2c_cmd_done) begin
                            r_owner                <= OWNER_NONE;
                            r_active_channel_valid <= 1'b0;
                            r_page_cache_valid     <= 1'b0;
                            r_recovery_active      <= 1'b0;
                            o_resp_error           <= 1'b1;
                            // 使用I2C core内部CDC及5拍滤波后的空闲状态，
                            // 不直接采样本模块端口上的异步SCL/SDA。
                            if (w_i2c_bus_idle) begin
                                r_bus_ok <= 1'b1;
                                o_resp_error_code <=
                                    `JWH_BUS_ERR_TIMEOUT_RECOVERED;
                            end else begin
                                r_bus_ok <= 1'b0;
                                o_resp_error_code <=
                                    `JWH_BUS_ERR_CLEAR_FAILED;
                            end
                            r_state <= ST_RESPONSE;
                        end
                    end

                    ST_RESPONSE: begin
                        o_resp_valid <= 1'b1;
                        if (o_resp_valid && i_resp_ready) begin
                            o_resp_valid <= 1'b0;
                            r_state      <= ST_IDLE;
                        end
                    end

                    default: begin
                        r_state <= ST_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
