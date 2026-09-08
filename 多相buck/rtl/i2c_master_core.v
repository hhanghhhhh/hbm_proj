`timescale 1ns / 1ps
`include "jwh6374_common_defs.vh"

/*
**定位**：纯物理层指令驱动器（Token-based）。无内部 FIFO，支持协议级解耦与全场景防死锁（SMBus 兼容）。

#### 1. 物理层与时钟对接 (Physical & Clock Rules)
*   **引脚映射**：仅提供 `_i` (入), `_o` (恒为0), `_t` (高阻/强下拉控制)。顶层**必须**例化开漏 `IOBUF`（`assign SCL = scl_t ? 1'bz : 1'b0;`）。
*   **同步设计**：全部逻辑与系统时钟 `i_clk` 同步。

#### 2. 指令流与握手规范 (Command Handshake)
*   遵守标准 AXI-Stream `Valid/Ready` 铁律（`valid` 绝不能等待 `ready`）。
*   **指令集 (`i_cmd_type`)**：
    *   `3'b001`: START (总线启动 / 重复启动)
    *   `3'b010`: WRITE (发送 `i_tx_data`)
    *   `3'b011`: READ (接收数据，并依据 `i_rx_ack_ctrl` 回复 0=ACK / 1=NACK)
    *   `3'b100`: STOP (释放总线)
    *   `3'b101`: BUS_CLEAR (9 个时钟的总线盲打急救)

#### 3. 事务时序与强制挂起 (Transaction & ST_HOLD)
*   **HOLD 挂起机制**：执行完 START、WRITE、READ 后，若上层未下发新指令，IP 会自动将 **SCL 强行拉低（SCL=0）**，挂起总线以保护现场（防止产生假 START/STOP）。
*   **收尾铁律**：无论通信成功、收到 NACK 还是提前终止，只要不打算继续通信，**必须以 `STOP` 指令作为绝对终点**，IP 才会松开总线回到 IDLE。

#### 4. 异常分类与强制恢复流 (Exception Handling - CRITICAL)

异常严格分为两类，由 IP 的硬件看门狗和状态机独立监控，上层必须按规约处理：

**异常 A：逻辑级被拒 (`o_err_nack == 1`)**
*   **触发**：WRITE 结束后，从机未响应 ACK。
*   **IP 状态**：标志置位，**安全挂机于 `ST_HOLD` (SCL=0)**，IP 未死锁。
*   **驱动处理流**：
    1. 捕获 NACK 报警，清空软件侧未发送的指令流。
    2. 主动下发一条 `STOP` 指令。
    3. IP 正常执行 STOP 释放总线，自动清除 NACK 标志，回到 IDLE。

**异常 B：全场景死锁 / 超时报警 (`o_err_timeout == 1`)**
*   **看门狗触发矩阵（35ms 限时，四大死锁场景统杀）**：
    1. **物理层 SCL 死锁**：IP 释放 SCL，但线依然为 0（从机时钟延展过长 / 物理短路）。
    2. **物理层 SDA 幽灵死锁**：IP 处于 IDLE（本该空闲），但 SDA 被外部异常拉低。
    3. **软件层指令断粮**：IP 停留在 `ST_HOLD` 等待新指令超 35ms（软件宕机，防止总线被永久劫持）。
    4. **软件层 RX 反压致死**：IP 读完 1 Byte 抛出 `rx_valid`，但上层 `rx_ready=0` 超 35ms（DMA/FIFO卡死）。
*   **IP 状态**：彻底锁定（Bricked），**无视所有常规指令**（`o_cmd_ready` 恒为 0），防止产生乱码波形。
*   **驱动处理流（必须遵循）**：
    1. 捕获 Timeout 报警。
    2. 下发 1 拍 `i_flush = 1` 脉冲（解冻 IP 核，计数器清零，强制拉回 IDLE）。
    3. 紧接着下发 `BUS_CLEAR` 指令。
    4. IP 将自动打出最多 9 个 SCL 时钟试图踢醒从机，并**自动附送 1 个 STOP 波形**。
    5. *(终极防线)*: 如果执行 `BUS_CLEAR` 后依然触发 Timeout，说明发生严重物理级或芯片级死锁。交由 PMIC 切断从机电源硬重启，勿再尝试软件修复。
    
*/

module i2c_master_core #(
    parameter SYS_CLK_FREQ  = 100_000_000, // 系统时钟频率 (默认 100MHz)
    parameter I2C_BAUD_RATE = 400_000,     // I2C 目标波特率 (默认 400kHz Fast Mode)
    parameter TIMEOUT_MS    = 35           // 总线死锁超时时间 (默认 35ms)
)(
    // 1. 系统与复位组
    input  wire        i_clk,
    input  wire        i_rst_n,

    // 2. 用户逻辑控制组 (Token 指令流接口)
    input  wire        i_cmd_valid,
    output wire        o_cmd_ready,
    output reg         o_cmd_done,          // Token 物理执行完成，单周期脉冲
    input  wire [2:0]  i_cmd_type,
    input  wire [7:0]  i_tx_data,
    input  wire        i_rx_ack_ctrl,      // 读数据时的回应: 0=ACK, 1=NACK
    input  wire        i_rx_ready,         // RX 方向反压，0代表上层FIFO满，主机将挂起SCL
    output reg         o_rx_valid,
    output reg  [7:0]  o_rx_data,
    input  wire        i_flush,            // 发生异常时，上层主动复位/清空当前状态

    // 3. 用户逻辑状态与报警组
    output reg         o_err_nack,         // 收到对端 NACK 报警
    output reg         o_err_timeout,      // 总线死锁超时报警
    output wire        o_bus_idle,         // 状态机空闲且滤波后的SCL/SDA均为高

    // 4. I2C 物理层接口 (三态控制)
    input  wire        i_scl_i,
    output wire        o_scl_o,
    output wire        o_scl_t,            // 1:高阻释放(总线为1); 0:强下拉(总线为0)
    input  wire        i_sda_i,
    output wire        o_sda_o,
    output wire        o_sda_t             // 1:高阻释放(总线为1); 0:强下拉(总线为0)
);

    // =========================================================================
    // 常量与参数定义
    // =========================================================================
    
    // FSM 状态定义
    localparam ST_IDLE        = 4'd0;
    localparam ST_START       = 4'd1;
    localparam ST_DATA_WR     = 4'd2;
    localparam ST_ACK_WR      = 4'd3;
    localparam ST_DATA_RD     = 4'd4;
    localparam ST_ACK_RD      = 4'd5;
    localparam ST_STOP        = 4'd6;
    localparam ST_BUS_FREE    = 4'd7;
    localparam ST_BUS_CLEAR   = 4'd8;
    localparam ST_HOLD        = 4'd9;

    // 波特率与超时计算
    localparam BAUD_DIV_CNT   = SYS_CLK_FREQ / I2C_BAUD_RATE / 4;
    localparam TIMEOUT_CYCLES = (SYS_CLK_FREQ / 1000) * TIMEOUT_MS;

    // =========================================================================
    // 内部信号声明
    // =========================================================================
    
    // 三态控制寄存器
    reg  r_scl_t;
    reg  r_sda_t;
    
    // I2C 物理层固定输出为 0
    assign o_scl_o = 1'b0;
    assign o_sda_o = 1'b0;
    assign o_scl_t = r_scl_t;
    assign o_sda_t = r_sda_t;

    // 跨时钟域与数字滤波信号
    reg  [1:0] scl_cdc;
    reg  [1:0] sda_cdc;
    reg  [4:0] scl_shift;
    reg  [4:0] sda_shift;
    reg        scl_sync;
    reg        sda_sync;

    // 波特率与相位发生器信号
    reg  [15:0] baud_cnt;
    reg  [1:0]  phase_idx;
    reg         phase_tick;  // 单周期脉冲，指示进入下一个 Phase
    wire        stall_req;   // 暂停波特率发生器计数的请求信号

    // 主状态机信号
    reg  [3:0] fsm_state;
    reg  [3:0] bit_cnt;      // 发送/接收的位数计数器
    reg  [7:0] shift_reg;    // 移位寄存器
    
    // 超时看门狗信号
    reg  [31:0] wd_cnt;

    // =========================================================================
    // 1. 输入去抖与数字滤波 (Glitch Filter)
    // =========================================================================
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            scl_cdc   <= 2'b11;
            sda_cdc   <= 2'b11;
            scl_shift <= 5'h1F;
            sda_shift <= 5'h1F;
            scl_sync  <= 1'b1;
            sda_sync  <= 1'b1;
        end else begin
            // CDC 两级同步
            scl_cdc <= {scl_cdc[0], i_scl_i};
            sda_cdc <= {sda_cdc[0], i_sda_i};

            // 移位寄存器采样
            scl_shift <= {scl_shift[3:0], scl_cdc[1]};
            sda_shift <= {sda_shift[3:0], sda_cdc[1]};

            // 只有连续 5 个时钟周期电平一致，才确认翻转 (滤除高频毛刺)
            if (scl_shift == 5'b00000)      scl_sync <= 1'b0;
            else if (scl_shift == 5'b11111) scl_sync <= 1'b1;

            if (sda_shift == 5'b00000)      sda_sync <= 1'b0;
            else if (sda_shift == 5'b11111) sda_sync <= 1'b1;
        end
    end

    // =========================================================================
    // 2. 超时看门狗 (Watchdog)
    // =========================================================================
    // 看门狗触发条件 (满足其一即可)：
    // 条件1 (SCL 物理死锁) : 主机期望释放 SCL (r_scl_t==1)，但物理线上 SCL 仍然为 0。
    // 条件2 (SDA 幽灵死锁) : 状态机处于 IDLE (总线应空闲)，但 SDA 被外部强制拉低。
    // 条件3 (软件不给指令) : 上层软件跑飞，导致总线无限期停留在 HOLD。
    // 条件4 (软件不收数据) : 上层 FIFO 满且卡死，导致主机无限期拉低 SCL 反压总线。

    wire wd_trigger_cond = 
        (r_scl_t == 1'b1 && scl_sync == 1'b0 && fsm_state != ST_BUS_CLEAR) || 
        (fsm_state == ST_IDLE && sda_sync == 1'b0) || 
        (fsm_state == ST_HOLD) || 
        (fsm_state == ST_ACK_RD && phase_idx == 2'd0 && o_rx_valid && !i_rx_ready);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            wd_cnt        <= 32'd0;
            o_err_timeout <= 1'b0;
        end else begin
            if (i_flush) begin
                wd_cnt        <= 32'd0;
                o_err_timeout <= 1'b0;
            end else if (wd_trigger_cond) begin
                if (wd_cnt < TIMEOUT_CYCLES) begin
                    wd_cnt <= wd_cnt + 1'b1;
                end else if (wd_cnt == TIMEOUT_CYCLES) begin
                    o_err_timeout <= 1'b1; // 触发超时，锁定状态直到上层发送 flush
                end
            end else begin
                wd_cnt <= 32'd0;
            end
        end
    end



    // =========================================================================
    // 3. 4-Phase 波特率与相位发生器 (支持时钟延展与 RX 反压)
    // =========================================================================
    
    // 停滞(Stall)条件判定：
    // 条件1: 处于 IDLE 状态时，关闭发生器节能。
    // 条件2: 等待新指令时，在 Phase 0 拉低 SCL 后主动挂起时钟
    // 条件3: 从机时钟延展 (Clock Stretching) - 主机在 Phase 2 (SCL拉高) 等待 scl_sync 变高。排除 ST_BUS_CLEAR。
    // 条件4: RX 反压 (Backpressure) - 接收完8bit进入ACK应答周期前的 Phase 0 时，如果上层无准备，主机主动挂起 SCL 保持低电平。
    assign stall_req = (fsm_state == ST_IDLE) ||
                       (fsm_state == ST_HOLD && phase_idx == 2'd0 && !i_cmd_valid) || 
                       (phase_idx == 2'd2 && r_scl_t == 1'b1 && scl_sync == 1'b0 && fsm_state != ST_BUS_CLEAR) ||
                       (fsm_state == ST_ACK_RD && phase_idx == 2'd0 && o_rx_valid && !i_rx_ready);

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            baud_cnt   <= 16'd0;
            phase_idx  <= 2'd0;
            phase_tick <= 1'b0;
        end else begin
            phase_tick <= 1'b0;
            
            if (i_flush) begin
                baud_cnt   <= 16'd0;
                phase_idx  <= 2'd0;
            end else if (!stall_req) begin
                if (baud_cnt < BAUD_DIV_CNT - 1) begin
                    baud_cnt <= baud_cnt + 1'b1;
                end else begin
                    baud_cnt   <= 16'd0;
                    phase_idx  <= phase_idx + 1'b1;
                    phase_tick <= 1'b1; // 产生 Phase 切换脉冲
                end
            end else if (fsm_state == ST_IDLE) begin
                // IDLE 期间保持计数器清零，必须将相位置为 3！这样启动后的第一次累加才会变成 0，精准切入 Phase 0
                baud_cnt  <= 16'd0;
                phase_idx <= 2'd3;
            end
        end
    end

    // =========================================================================
    // 4. 主机 FSM (基于 Token 机制与 4 相位调度)
    // =========================================================================

    // 只有在 IDLE (总线全空闲) 和 HOLD (SCL被按在低电平) 才能接收新指令
    // 超时后不接受指令，必须 i_flush 以后，复位模块
    assign o_cmd_ready = ((fsm_state == ST_IDLE) || (fsm_state == ST_HOLD)) && (!o_err_timeout);

    // 只向上层暴露经过CDC和5拍滤波后的总线状态。不能用o_cmd_ready代替，
    // 因为ST_HOLD同样ready，但此时总线仍处于一笔事务中。
    assign o_bus_idle = (fsm_state == ST_IDLE) &&
                        r_scl_t && r_sda_t && scl_sync && sda_sync;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            fsm_state  <= ST_IDLE;
            r_scl_t    <= 1'b1;
            r_sda_t    <= 1'b1;
            bit_cnt    <= 4'd0;
            shift_reg  <= 8'd0;
            o_rx_valid <= 1'b0;
            o_rx_data  <= 8'd0;
            o_err_nack <= 1'b0;
            o_cmd_done <= 1'b0;
        end else if (i_flush) begin
            // 异常恢复时的强制归位
            fsm_state  <= ST_IDLE;
            r_scl_t    <= 1'b1;
            r_sda_t    <= 1'b1;
            o_rx_valid <= 1'b0;
            o_err_nack <= 1'b0;
            o_cmd_done <= 1'b0;
        end else begin
            // 默认拉低；各 Token 真正完成时置高一个系统时钟周期。
            o_cmd_done <= 1'b0;

            // -----------------------------------------------------------------
            // (A) RX Valid 标准 AXI-Stream 握手清除逻辑
            // -----------------------------------------------------------------
            if (o_rx_valid && i_rx_ready) begin
                o_rx_valid <= 1'b0;
            end

            // -----------------------------------------------------------------
            // (B) 核心 FSM 调度流
            // -----------------------------------------------------------------
            if ((fsm_state == ST_IDLE || fsm_state == ST_HOLD) && (i_cmd_valid && !o_err_timeout)) begin
                o_err_nack <= 1'b0; // 收到新指令，清除之前的 NACK 记录
                bit_cnt    <= 4'd0;
                
                case (i_cmd_type)
                    `I2C_CMD_START:     fsm_state <= ST_START;
                    `I2C_CMD_WRITE:     begin fsm_state <= ST_DATA_WR; shift_reg <= i_tx_data; end
                    `I2C_CMD_READ:      fsm_state <= ST_DATA_RD;
                    `I2C_CMD_STOP:      fsm_state <= ST_STOP;
                    `I2C_CMD_BUS_CLEAR: fsm_state <= ST_BUS_CLEAR;
                    default:       fsm_state <= ST_IDLE;
                endcase
            end 
            // 所有的总线动作严格发生在 phase_tick 脉冲点
            else if (phase_tick) begin
                case (fsm_state)

                    // -----------------------------------------
                    // HOLD
                    // -----------------------------------------
                    ST_HOLD: begin
                        if (phase_idx == 0) r_scl_t <= 1'b0; // 死死拉低 SCL，等待 i_cmd_valid 解除 stall
                    end

                    // -----------------------------------------
                    // START / REPEATED START
                    // -----------------------------------------
                    ST_START: begin
                        case (phase_idx)
                            0: begin r_scl_t <= 1'b0; end
                            1: begin r_sda_t <= 1'b1; end                  // 确保SDA先释放
                            2: begin r_scl_t <= 1'b1; end                  // 释放SCL
                            3: begin
                                r_sda_t    <= 1'b0;
                                fsm_state  <= ST_HOLD;
                                o_cmd_done <= 1'b1;
                            end // SCL高电平下把SDA拉低，生成START！发完 START，进入 HOLD 保持 SCL 拉低！
                        endcase
                    end
                    
                    // -----------------------------------------
                    // WRITE (8-bit Data)
                    // -----------------------------------------
                    ST_DATA_WR: begin
                        case (phase_idx)
                            0: begin r_scl_t <= 1'b0; end
                            1: begin r_sda_t <= shift_reg[7]; shift_reg <= {shift_reg[6:0], 1'b0}; end // Hold Time 保障
                            2: begin r_scl_t <= 1'b1; end
                            3: begin
                                if (bit_cnt == 4'd7) begin
                                    fsm_state <= ST_ACK_WR;
                                    bit_cnt   <= 4'd0;
                                end else begin
                                    bit_cnt   <= bit_cnt + 1'b1;
                                end
                            end
                        endcase
                    end
                    
                    // -----------------------------------------
                    // WRITE ACK (Wait for Slave ACK)
                    // -----------------------------------------
                    ST_ACK_WR: begin
                        case (phase_idx)
                            0: begin r_scl_t <= 1'b0; end
                            1: begin r_sda_t <= 1'b1; end // 释放 SDA 给从机去拉低
                            2: begin r_scl_t <= 1'b1; end
                            3: begin
                                o_err_nack <= sda_sync; // 采样: 0=ACK, 1=NACK
                                fsm_state  <= ST_HOLD;  // 收完 ACK，进入 HOLD 保持 SCL 拉低等下个字节！
                                o_cmd_done <= 1'b1;
                            end
                        endcase
                    end

                    // -----------------------------------------
                    // READ (8-bit Data)
                    // -----------------------------------------
                    ST_DATA_RD: begin
                        case (phase_idx)
                            0: begin r_scl_t <= 1'b0; end
                            1: begin r_sda_t <= 1'b1; end // 持续释放 SDA
                            2: begin r_scl_t <= 1'b1; end
                            3: begin
                                shift_reg <= {shift_reg[6:0], sda_sync}; // SCL高电平正中采样
                                if (bit_cnt == 4'd7) begin
                                    fsm_state  <= ST_ACK_RD;
                                    bit_cnt    <= 4'd0;
                                    o_rx_data  <= {shift_reg[6:0], sda_sync};
                                    o_rx_valid <= 1'b1; // 抛出有效数据供上层抓取
                                end else begin
                                    bit_cnt    <= bit_cnt + 1'b1;
                                end
                            end
                        endcase
                    end
                    
                    // -----------------------------------------
                    // READ ACK (Host sends ACK/NACK)
                    // *注意: Phase 0 具备 stall_req 机制，完美实现反压*
                    // -----------------------------------------
                    ST_ACK_RD: begin
                        case (phase_idx)
                            0: begin r_scl_t <= 1'b0; end 
                            1: begin r_sda_t <= i_rx_ack_ctrl; end // 用户指示回 ACK 还是 NACK
                            2: begin r_scl_t <= 1'b1; end
                            3: begin
                                fsm_state  <= ST_HOLD;
                                o_cmd_done <= 1'b1;
                            end  // 进入 HOLD 保持 SCL 拉低等下个字节！
                        endcase
                    end
                    
                    // -----------------------------------------
                    // STOP
                    // -----------------------------------------
                    ST_STOP: begin
                        case (phase_idx)
                            0: begin r_scl_t <= 1'b0; end
                            1: begin r_sda_t <= 1'b0; end // 确保SDA为低
                            2: begin r_scl_t <= 1'b1; end
                            3: begin r_sda_t <= 1'b1; fsm_state <= ST_BUS_FREE; bit_cnt <= 4'd0; end // 生成STOP！
                        endcase
                    end

                    // -----------------------------------------
                    // BUS_FREE (强制空闲时间 T_BUF)
                    // -----------------------------------------
                    ST_BUS_FREE: begin
                        // 借用相位发生器等待 8 个 phase_tick (正好等同于 2 个波特周期)
                        if (bit_cnt < 4'd7) begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end else begin
                            fsm_state <= ST_IDLE;
                            o_cmd_done <= 1'b1;
                        end
                    end
                    
                    // -----------------------------------------
                    // BUS_CLEAR (死锁恢复: 打9个SCL)
                    // -----------------------------------------
                    ST_BUS_CLEAR: begin
                        case (phase_idx)
                            0: begin r_scl_t <= 1'b0; end
                            1: begin r_sda_t <= 1'b1; end // 主机全程释放 SDA
                            2: begin r_scl_t <= 1'b1; end
                            3: begin
                                if (bit_cnt == 4'd8) begin
                                    // 9个时钟打完，平滑切入 STOP 状态机去发起停止位
                                    fsm_state <= ST_STOP; 
                                    bit_cnt   <= 4'd0;
                                end else begin
                                    bit_cnt   <= bit_cnt + 1'b1;
                                end
                            end
                        endcase
                    end

                    default: fsm_state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
