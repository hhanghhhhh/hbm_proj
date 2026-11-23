# AD5560 控制与上电时序说明

## 5. FIN DAC 的完整数据链路与计算关系

### 5.1 完整链路

对于 Force Voltage，可以按下面的链路理解：

```text
上位机目标电压
      |
      v
FIN DAC x1 Register (0x08)
      |
      |  Ramp Function 直接修改的也是 x1
      v
Calibration Engine
      |  m: Gain Correction
      |  c: Offset Correction
      v
FIN DAC x2
      |
      | 是否立即更新由 LOAD 模式决定
      v
16-bit Resistor-String DAC
      |
      |  固定模拟增益 = 5.125
      |  VREF 通常 = 5 V
      v
Force DAC 模拟电压
      |
      |  Offset DAC 平移整个输出窗口
      |  DUTGND 提供基准
      v
Force Amplifier
      |
      v
FORCE / SENSE 闭环
      |
      v
DUT
```

其中：

- `x1`：SPI 可写、可读的目标码，也是 Ramp Engine 操作的数字码；
- `m/c`：Gain / Offset Correction 系数；
- `x2`：Calibration Engine 计算后真正加载到 resistor-string DAC 的数据字；
- `x2` 不支持通过 SPI 直接 Readback；
- `5.125` 是芯片内部固定的 DAC amplifier 模拟增益，不是可编程增益；
- `Offset DAC` 与校准寄存器 `c` 是两个不同概念。
- `LOAD` 控制的是经过 Calibration Engine 得到的新 `x2` 以及相关受 LOAD 控制的数据，什么时候真正加载到实际工作部分。

### 5.2 VREF 与固定 5.125 增益

AD5560 的 `VREF` 输入允许约 `2 V ~ 5 V`，通常采用 `5 V`。

内部 DAC amplifier 的固定增益为：

```text
G_DAC = 5.125
```

因此当：

```text
VREF = 5 V
```

原始 DAC 模拟跨度为：

```text
5.125 x 5 V = 25.625 V
```

需要注意：

> `25.625 V` 是 DAC 链路包含 overrange 的原始 span，不代表输出一定是 `0 ~ 25.625 V`，也不代表 AD5560 正常应用时定义了 25.625 V 的额定 Force span。

AD5560 标称 Force Voltage span 为约 `25 V`，额外的模拟增益用于给系统 gain/offset correction 留出校准余量。Offset DAC 可以在器件 headroom 允许的范围内上下移动这个电压窗口。

`5.125` 本身固定，不能通过寄存器关闭或修改；有效数字增益由 `m` register 另外控制。

---

## 6. 两种输出变化速度控制方式

### 6.1 Programmable Slew Rate

`DPS Register 2` 地址 `0x03`，`SR[2:0]` 位于 Bit[14:12]。

该功能通过改变 Force DAC 输出放大器相关内部补偿，限制模拟输出追踪目标值的速度。

Slew Rate 适合较快的受控电压变化。

### 6.2 Ramp Function 的本质

Ramp Function 的本质是：

> **Ramp Engine 直接在 FIN DAC `x1` code 上做加减；每一步得到新的 `x1` 后，再经过 Calibration Engine 计算新的 `x2`，最后更新实际 DAC。**


### 6.3 Ramp Step Size 寄存器

`0x3F` 的 `D6:D0` 定义 Step Size，以 `16 LSB` 为基本单位。

数据手册给出的关系为：

```text
0000000 -> 16 LSB （0 时至少为 1）
0000001 -> 16 LSB
0000010 -> 32 LSB
...
1111111 -> 2032 LSB （127 * 16）
```


这里的 LSB 应理解为 **FIN DAC x1 code 的 LSB**。

设：

```text
start     = 当前 FIN x1
end       = Ramp End Code
step      = Ramp step size
```

Ramp 的方向由当前 FIN `x1` 与 `Ramp End Code` 的大小关系决定。

如果最后剩余的 code 差小于一个完整 Step，最后一步自动缩小，使 FIN x1 恰好到达 End Code。

### 6.6 为什么数据手册写 16 LSB = 6.1 mV

当 `VREF = 5 V` 时，

```text
16 LSB ~= 5 * 5.125 * 16 / 65536  = 6.256 mV
```

但数据手册 Ramp 表使用的 `6.1mV`，因为数据手册使用的 `25 V nominal Force span` 的口径，因此：

```text
16 LSB ~= 25 * 16 / 65536  ~= 6.1 mV
```

本项目使用使用 `3 V Vref`，则得到：

```text
16 LSB ~= 3 * 5.125 * 16 / 655366  = 3.754 mV
```

### 6.7 RCLK Divider 与理论 Ramp 更新周期

`0x40` 的 `D7:D0` 定义 RCLK Divider：

```text
0   -> /1
1   -> /1
2   -> /2
3   -> /3
...
255 -> /255
```
Ramp 每一步都需要经过 Calibration Engine。数据手册说明 calibration delay 约为 `1.2 us`，并给出 Divider = 1 时外部 RCLK 最大约 `833 kHz`：

```text
1 / 833 kHz ~= 1.2 us
```


则稳态 Ramp step 的更新周期：

```text
T_STEP = D / F_RCLK
```

### 6.8 理论 Ramp 斜率公式

平均数字 Ramp 斜率可以按：

```text
SR = Delta_V_STEP / T_STEP
```

### 6.9 datasheet 的 0.775 V/us 与 833 kHz 说明

数据手册给出：

```text
VREF = 5 V
RCLK = 833 kHz
STEP = 2032 LSB
Divider = 1
Fastest Ramp Rate = 0.775 V/us
```

但如果把表中的 `2032 LSB ~= 775 mV` 直接除以：

```text
1 / 833 kHz ~= 1.2 us
```

得到的算术结果约为：

```text
775 mV / 1.2 us ~= 0.646 V/us
```

ADI EngineerZone 对该问题的答复指出，datasheet 中的 `0.775 V/us` 应理解为器件设计/characterization 给出的能力值，而不是简单按 `Step Voltage x 833 kHz` 推导得到的公式值。

实际 DUT 节点电压还会受到 Force Amplifier slew、负载电容、电流限制、环路稳定性以及线路压降等模拟因素影响。

## 9. Ramp 结束、中断与状态判断

### 9.1 Ramp 的结束条件

Ramp 会在以下情况之一发生时退出：

1. FIN x1 到达 Ramp End Code；
2. 控制器写 `0x42 = 0x0000` 执行 Interrupt Ramp；
3. 已使能的 Alarm 触发，使 Ramp 被中断。

被中断时，FIN DAC `x1` 停留在当时已经到达的值，并退出 Ramp Mode。

### 9.2 没有专用 RAMP_DONE 标志

AD5560 没有独立的 RAMP_DONE pin，也没有专门的 Ramp Complete status bit 供 FPGA 轮询。

### 9.3 FPGA 如何确认 Ramp 完成

此可以计算 Ramp 所需步数和预计时间。

如果需要进一步确认，可在预计完成后读取：

```text
FIN DAC x1 (0x08)
```

检查是否已经达到 Ramp End Code。

同时 FPGA 应监视 Alarm；如果 Ramp 期间 Alarm 先发生，应按 Ramp Abort 处理，而不能仅依赖预计结束时间。

---

## 12. 多颗 AD5560 的控制与同步

### 12.1 HW_INH 同步 Enable

如果多个 AD5560 已经预配置目标 FIN DAC，可以让多个器件共用一根 `HW_INH`，可实现多个 Force Amplifier 的硬件级同时 Enable。

### 12.3 多颗器件的 Ramp 时序

Ramp 没有公共硬件 Start pin。

多个 AD5560 必须分别执行：

```text
Write 0x41 = 0xFFFF
```

### 12.4 多通道在线同步电压变化

如果多个已经在线的通道需要在同一时刻由各自 V1 切换到新的 V2，并且同步精度高于顺序 SPI 写能够提供的水平，则 LOAD 更有价值。

### 12.5 GANG 并联输出

GANG 用于多颗 AD5560 并联提高输出电流。可采用 FV/FV 或 FV/FI；需要均流时优先采用 **Master FV + Slave FI**。

Slave 的 `SW6 = ON` 用于把前级 GANG reference 继续传到下一颗，**不是重新用本 Slave 的测量电流生成新的参考**。

FV/FI GANG 需满足以下约束：

- Master 与所有 Slave 使用相同 Current Range，并保持 Rsense 及测量链路匹配；
- Master 与 Slave 的 MI Gain 必须一致，否则相同 `SLAVE_IN` 电压不再对应相同电流；
- Slave 的 Current Clamp 必须关闭。若 `CLEN/LOAD` 仍作为 CLEN，实际 Clamp Enable 为软件 `CLEN` 与硬件 CLEN 的 OR，因此应同时保证软件 `CLEN = 0`、CLEN pin = Low；
- Master Clamp 可以保留，但总 GANG 限流值只能近似理解为并联路数乘以 Master 电流，不应作为高精度总电流限制；
- Master SENSE 应 Kelvin 接到实际 DUT 节点；各器件 DUTGND 使用同一 DUT ground reference；
- Slave FI 不直接照搬 Master 的 FV 补偿；进入 Slave FI 后器件会覆盖部分补偿参数，具体见“补偿模式与使用原则”；Master Compensation 按 DUT 负载条件配置；
- GANG reference 链路应尽量短，最后一级 `MASTER_OUT` 可不连接；Master 的 `SLAVE_IN` 不使用；
- `LOAD` 不能同步切换 `GANGMODE`。

进入或退出 GANG 时，正在改变 GANG 配置的 Slave 应保持 High-Z。典型进入顺序为：先关闭 Slave 输出并完成 Range、MI Gain、Clamp、Compensation 配置，再设置 Master=`01`、Slave=`11`，最后使能 Slave；退出时采用相反顺序，必要时先将 Master 输出降到安全电压。

---

## 14. 补偿模式与使用原则

AD5560 提供 Safe、Auto 和 Manual 三种 Force Amplifier 补偿方式。

### 14.1 模式选择

补偿模式主要由 `Compensation Register 1 (0x04)` 和 `Compensation Register 2 (0x05)` 控制：

| Manual，0x05[15] | SAFEMODE，0x04[7] | 实际模式 |
|---:|---:|---|
| 0 | 0 | Safe Mode |
| 0 | 1 | Auto Compensation |
| 1 | X | Manual Compensation |

因此 Manual 优先级最高；上电 / Reset 后默认先处于 Safe Mode。

### 14.2 Safe Mode

Safe Mode 使用器件内部预设的一组保守补偿参数，主要用于负载条件未知、初始化阶段或状态切换期间优先保证稳定。

Safe Mode 响应较慢，不建议作为正常 DUT 工作时长期固定使用。

### 14.3 Auto Compensation

Auto 模式下，由软件在 `0x04` 中给出 DUT 电容 `CDUT` 和 ESR 范围，器件据此自动选择 gm、CC、CF、RZ、RP 等补偿参数。

Auto 并不会自动测量 DUT 电容和 ESR，因此 DUT 类型或负载条件明显变化时，需要重新配置对应的 CDUT / ESR code。

配置原则：

- 不应高估 CDUT；
- 不应低估 ESR；
- 不确定时优先使用偏保守的配置，允许响应慢一些，不应以稳定性换速度。

Auto 模式下可读取 `0x05`，查看器件最终选择的补偿参数，便于开发阶段表征。

### 14.4 Manual Compensation

Manual 模式下设置 `0x05[15] = 1`，由软件直接设置 gm、RZ、RP、CF、CC 等补偿参数。

适合：

- PCB、Socket、DUT 类型基本固定，并已通过实测完成稳定性和瞬态验证；
- 负载电容在 `0 ~ Cmax` 较大范围内变化，希望使用一套固定、经过验证的保守参数覆盖整个范围。

量产时可以针对不同 DUT / Range 固化不同 Manual Compensation Profile。

### 14.6 GANG 模式

FV/FI GANG 时：

- Master 仍工作在 FV，负责公共 DUT 节点的电压闭环，因此 Master Compensation 应按 DUT 电容、ESR 和动态性能要求选择 Auto 或经过验证的 Manual；
- Slave FI 负责跟随 Master 电流，不应简单复制 Master 的 FV 补偿参数；
- 进入 Slave FI 后，器件内部会覆盖部分补偿设置，例如 `CF = 0`、`RZ = 0`，并限制 gm，以满足 FI 跟随环路稳定性；
- 这些 Slave FI 内部 override 不应依赖寄存器 Readback 判断；
- GANG 配置和补偿切换应在 Slave 保持 High-Z 时完成，再将 Slave 接入公共 DUT 节点。

因此可以简单记为：

> Safe 用于未知状态和初始化；Auto 用于已知 C / ESR 的正常优化；Manual 用于已经充分表征后的固定配置；Slave FI 按 GANG FI 的内部补偿规则工作，不照搬 Master FV 参数。

# AD5560 项目上下电时序方案

## 6. Ramp 完成与 Alarm

AD5560 没有独立的 `RAMP_DONE` 引脚或 Ramp Complete 状态位。

FPGA 采用以下方式管理 Ramp：

```text
1. 根据 Start Code、End Code、Step、RCLK Divider 和 RCLK 计算预计 Ramp 时间；
2. 到达预计结束时间后留出必要裕量；
3. 需要确认时可读回 `FIN DAC x1 (0x08)`，检查是否已经到达 End Code。
```

一定要确保 ramp 完成，因为 ramp 会被 alarm 打断，很可能报错导致没有完成。紧急下电可不用 ramp 功能。

AD5560 不做后台状态寄存器轮询。

收到 `ALARM` 后，由 `System Controller` 暂停新的 Sequence 命令派发并启动 `Alarm Handler`，事件触发读取 Alarm / Fault Status 寄存器。已经被 Driver 接受的 SPI 事务不取消。

Alarm Handler 完成状态读取后，是否继续 Sequence 或转入故障处理由系统策略决定。

---

## 7. 故障处理原则

运行过程中发生 AD5560 Alarm 时，FPGA 读取对应状态寄存器进行故障定位，再由系统策略决定是否继续运行。

如果 SPI / BUSY 等底层执行出现系统级异常，则停止当前上下电流程。需要立即关断输出时，可使用全局 `HW_INH` 进入 High-Z，不要求等待正常 Ramp Down 完成。

具体状态机和模块接口见 `SYSTEM_CONTROLLER_DESIGN.md` 与 `POWER_SEQUENCE_ENGINE_DESIGN.md`。


## 6. SPI 数字接口

### 6.1 相关引脚

| 引脚 | 方向 | 作用 |
|---|---|---|
| `SYNC` | Input | SPI Frame Sync，低有效，等价于器件片选 |
| `SCLK` | Input | SPI 时钟，Active Falling Edge |
| `SDI` | Input | 串行数据输入 |
| `SDO` | Output | 寄存器 Readback 输出 |
| `BUSY` | Open-Drain Output | 内部更新忙指示，低有效 |
| `RESET` | Input | 寄存器复位 |

纯写模式 SCLK 最高可到 **50 MHz**。

Readback 时最大 SCLK 与 DVCC 有关：

| DVCC | Readback 最大 SCLK |
|---|---:|
| 2.3 V ~ 2.7 V | 12 MHz |
| 2.7 V ~ 3.3 V | 15 MHz |
| 4.5 V ~ 5.5 V | 20 MHz |

### 6.2 24-bit 命令格式

每个命令固定 24 bit，MSB First：

```text
Bit23       Bit22 ........ Bit16   Bit15 ........ Bit0
+----+      +------------------+   +------------------+
|R/W |      | Address[6:0]     |   | Data[15:0]       |
+----+      +------------------+   +------------------+
```

### 6.4 BUSY

`BUSY` 为 Open-Drain、Active-Low：

```text
BUSY = 0 -> 内部仍在处理
BUSY = 1 -> 当前内部更新完成
```

主要时序量级：

- DAC `x1` write：最大约 1.5 µs；
- 其他寄存器 write：最大约 280 ns；
- RESET：Timing Table 最大约 400 µs。

多颗 AD5560 的 BUSY 可以 wired-OR，但共享后只能知道组级 Busy。

### 6.6 Readback 是两帧

第一帧发送 Read Request，第二帧发送 NOP 并从 SDO 接收结果：

```text
Frame 1: Read(addr)
SYNC high >= 250 ns
Frame 2: NOP + SDO readback
```
