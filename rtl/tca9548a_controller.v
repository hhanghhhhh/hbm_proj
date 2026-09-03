`timescale 1ns / 1ps
`include "jwh6374_common_defs.vh"

module tca9548a_controller #(
    parameter [6:0]  P_TCA_ADDR         = 7'h70,  // TCA9548A 默认器件地址
    parameter [31:0] P_DEAD_TIME_CYCLES = 32'd500 // 静默延时周期数 (如: 50MHz下500拍 = 10us)
)(
    input  wire        i_clk,
    input  wire        i_rst_n,
    input  wire        i_flush,               // 上层主状态机下发的复位/清理脉冲

    // =========================================================
    // 上行接口 (对接 模块4：Main Polling FSM)
    // =========================================================
    // 1. 请求通道 (Receive Request)
    input  wire        i_cmd_valid,
    output reg         o_cmd_ready,
    input  wire [2:0]  i_cmd_ch_sel,          // 目标通道号 (0~7)
    input  wire        i_cmd_en,              // 1:打开指定通道, 0:全关隔离

    // 2. 响应通道 (Transmit Response)
    output reg         o_resp_valid,
    input  wire        i_resp_ready,
    output reg         o_resp_error,          // 0:成功, 1:底层报错(NACK)

    // 3. 严重异常透传
    output wire        o_err_timeout,         // 透传给主状态机，请求灾难复位

    // =========================================================
    // 下行接口 (对接 模块1：Standard I2C Master)
    // =========================================================
    // 1. 发送与控制流 (TX / Ctrl)
    output reg         o_i2c_cmd_valid,
    input  wire        i_i2c_cmd_ready,
    input  wire        i_i2c_cmd_done,
    output reg  [2:0]  o_i2c_cmd_type,
    output reg  [7:0]  o_i2c_tx_data,
    output wire        o_i2c_flush,           // 透传给底层 I2C 的清零信号

    // 2. 接收控制（本模块只写 TCA9548A，不发起读事务）
    output wire        o_i2c_rx_ack_ctrl,
    output wire        o_i2c_rx_ready,

    // 3. 报警流
    input  wire        i_i2c_err_nack,
    input  wire        i_i2c_err_timeout
);

    // =========================================================
    // 内部常量与连线
    // =========================================================
    // FSM 状态定义
    localparam [3:0] ST_IDLE            = 4'd0,
                     ST_SEND_START      = 4'd1,
                     ST_WAIT_START_DONE = 4'd2,
                     ST_SEND_ADDR       = 4'd3,
                     ST_WAIT_ADDR_DONE  = 4'd4,
                     ST_SEND_MASK       = 4'd5,
                     ST_WAIT_MASK_DONE  = 4'd6,
                     ST_SEND_STOP       = 4'd7,
                     ST_WAIT_STOP_DONE  = 4'd8,
                     ST_DEAD_TIME       = 4'd9,
                     ST_RESP            = 4'd10,
                     ST_FROZEN          = 4'd11;

    // 内部寄存器
    reg [3:0]  r_state;
    reg [7:0]  r_mask_data;
    reg [31:0] r_delay_cnt;
    reg        r_err_flag;

    // =========================================================
    // 静态接口系留 (Tie-off) 与透传
    // =========================================================
    assign o_err_timeout     = i_i2c_err_timeout;
    assign o_i2c_flush       = i_flush;
    // RX 侧静态配置：默认回复 ACK(0)，始终 Ready(1) 防止底层 RX FIFO 反压死锁
    assign o_i2c_rx_ack_ctrl = 1'b0; 
    assign o_i2c_rx_ready    = 1'b1;

    // =========================================================
    // 核心控制状态机
    // =========================================================
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            r_state         <= ST_IDLE;
            o_cmd_ready     <= 1'b0;
            o_resp_valid    <= 1'b0;
            o_resp_error    <= 1'b0;
            o_i2c_cmd_valid <= 1'b0;
            o_i2c_cmd_type  <= 3'd0;
            o_i2c_tx_data   <= 8'd0;
            r_mask_data     <= 8'd0;
            r_delay_cnt     <= 32'd0;
            r_err_flag      <= 1'b0;
        end 
        else if (i_flush) begin
            // 收到上层 Flush，立刻清理战场并回到空闲
            r_state         <= ST_IDLE;
            o_cmd_ready     <= 1'b0;
            o_resp_valid    <= 1'b0;
            o_i2c_cmd_valid <= 1'b0;
        end
        else if (i_i2c_err_timeout) begin
            // 发生底层死锁，主动冻结，等待 i_flush 降临
            r_state         <= ST_FROZEN;
            o_cmd_ready     <= 1'b0;
            o_resp_valid    <= 1'b0;
            o_i2c_cmd_valid <= 1'b0;
        end
        else begin
            case (r_state)
                // -------------------------------------------------
                // 空闲等待与参数锁存
                // -------------------------------------------------
                ST_IDLE: begin
                    o_cmd_ready <= 1'b1;
                    if (i_cmd_valid && o_cmd_ready) begin
                        o_cmd_ready <= 1'b0;
                        r_err_flag  <= 1'b0;
                        
                        // 直接在握手时完成译码锁存 (抛弃多余脉冲逻辑)
                        if (i_cmd_en) begin
                            r_mask_data <= 8'b0000_0001 << i_cmd_ch_sel;
                        end else begin
                            r_mask_data <= 8'h00;
                        end
                        r_state <= ST_SEND_START;
                    end
                end

                // -------------------------------------------------
                // Token 1: 发送 START
                // -------------------------------------------------
                ST_SEND_START: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_START;
                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_START_DONE;
                    end
                end
                ST_WAIT_START_DONE: begin
                    // 等待底层完成脉冲，说明 START 已执行并进入 HOLD 状态
                    if (i_i2c_cmd_done) begin
                        r_state <= ST_SEND_ADDR;
                    end
                end

                // -------------------------------------------------
                // Token 2: 发送 Device Address + Write(0)
                // -------------------------------------------------
                ST_SEND_ADDR: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_WRITE;
                    o_i2c_tx_data   <= {P_TCA_ADDR, 1'b0};
                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_ADDR_DONE;
                    end
                end
                ST_WAIT_ADDR_DONE: begin
                    if (i_i2c_cmd_done) begin
                        // 地址阶段完成，检测 NACK 状态
                        if (i_i2c_err_nack) begin
                            r_err_flag <= 1'b1;       // 拦截异常A
                            r_state    <= ST_SEND_STOP; // 跳过数据发送，强制去发 STOP
                        end else begin
                            r_state    <= ST_SEND_MASK; // 成功，继续发掩码数据
                        end
                    end
                end

                // -------------------------------------------------
                // Token 3: 发送 通道控制 Mask
                // -------------------------------------------------
                ST_SEND_MASK: begin
                    o_i2c_cmd_valid <= 1'b1;
                    o_i2c_cmd_type  <= `I2C_CMD_WRITE;
                    o_i2c_tx_data   <= r_mask_data;
                    if (o_i2c_cmd_valid && i_i2c_cmd_ready) begin
                        o_i2c_cmd_valid <= 1'b0;
                        r_state         <= ST_WAIT_MASK_DONE;
                    end
                end
                ST_WAIT_MASK_DONE: begin
                    if (i_i2c_cmd_done) begin
                        if (i_i2c_err_nack) begin
                            r_err_flag <= 1'b1;
                        end
                        // 无论有无 NACK，已是最后操作，均去发 STOP 收尾
                        r_state <= ST_SEND_STOP;
                    end
                end

                // -------------------------------------------------
                // Token 4: 发送 STOP 收尾 / 清理总线
                // -------------------------------------------------
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
                        // 底层执行完 STOP 自动清除了自身的 NACK 标记，总线安全释放
                        if (r_err_flag) begin
                            r_state     <= ST_RESP; // 若发生过NACK，跳过静默延时，直接报错
                        end else begin
                            r_delay_cnt <= 32'd0;
                            r_state     <= ST_DEAD_TIME; // 切换成功，进入 Dead Time
                        end
                    end
                end

                // -------------------------------------------------
                // 核心动作：静默延时防毛刺 (Dead Time)
                // -------------------------------------------------
                ST_DEAD_TIME: begin
                    if (P_DEAD_TIME_CYCLES == 0) begin
                        r_state <= ST_RESP;
                    end else if (r_delay_cnt >= (P_DEAD_TIME_CYCLES - 32'd1)) begin
                        r_state <= ST_RESP;
                    end else begin
                        r_delay_cnt <= r_delay_cnt + 1'b1;
                    end
                end

                // -------------------------------------------------
                // 响应上层
                // -------------------------------------------------
                ST_RESP: begin
                    o_resp_valid <= 1'b1;
                    o_resp_error <= r_err_flag;
                    
                    if (o_resp_valid && i_resp_ready) begin
                        o_resp_valid <= 1'b0;
                        r_state      <= ST_IDLE;
                    end
                end

                // -------------------------------------------------
                // 灾难冻结状态
                // -------------------------------------------------
                ST_FROZEN: begin
                    // 等待外部 i_flush 解锁，屏蔽一切操作
                    o_cmd_ready     <= 1'b0;
                    o_resp_valid    <= 1'b0;
                    o_i2c_cmd_valid <= 1'b0;
                end

                default: begin
                    r_state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
