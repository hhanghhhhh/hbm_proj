# AD5560 FPGA 控制与寄存器使用指南

## 1. 文档目的

本文面向使用 FPGA 控制 AD5560 的开发人员，从“如何通过数字接口控制器件”的角度整理 AD5560 Rev.F 数据手册中的主要内容。

重点包括：

- AD5560 能完成哪些功能；
- SPI 通信格式、寄存器写入和 Readback；
- `RESET`、`BUSY`、`SYNC`、`SDO` 等数字接口；
- 主要控制寄存器的作用；
- Force Voltage、Current Range、Measure、Clamp、Comparator；
- `SW_INH` / `HW_INH` 与输出使能；
- Alarm 配置、故障读取与清除；
- Slew Rate 和 Ramp Function；
- Calibration Engine 的内部工作机制；
- Compensation、LOAD、Diagnostic 等功能；
- FPGA 侧推荐的模块划分和控制流程。

本文主要依据 Analog Devices **AD5560 Rev.F Data Sheet** 整理。模拟外围、电源轨、PCB、散热和外部补偿元件等仍应以原始数据手册为最终依据。

> 本文重点是 AD5560 自身机理和 FPGA 控制接口。已有的 [`AD5560_CONTROL.md`](./AD5560_CONTROL.md) 更侧重 DUT 上下电、`SW_INH/HW_INH`、Slew Rate 和 Ramp 时序。

---

## 2. AD5560 是什么

AD5560 是一颗单通道可编程 DPS（Device Power Supply），主要用于 ATE 中给 DUT 供电和测量。

从 FPGA 控制角度，可以把它理解为：

```text
                 +-------------------------+
FPGA SPI ------> | Control Registers       |
                 | DAC / Range / Alarm     |
                 +------------+------------+
                              |
                              v
VREF ---> FIN DAC ---> Force Amplifier ---> FORCE / EXTFORCE ---> DUT
                           ^                         |
                           |                         |
                     SENSE / DUTGND <----------------+
                           |
                           +--> Current Measure
                           +--> Voltage Measure
                           +--> Comparator
                           +--> Current Clamp
                           +--> Kelvin Alarm
                           +--> MEASOUT ---> 外部 ADC
```

主要功能包括：

1. **FV（Force Voltage）**：设定 DUT 电压；
2. **MI（Measure Current）**：测量 DUT 电流；
3. **MV（Measure Voltage）**：测量 DUT 电压；
4. FNMV 等高阻测量模式；
5. 5 档片内电流量程和 2 档外部高电流量程；
6. 正负方向 Current Clamp；
7. 电流/电压窗口比较器；
8. Kelvin Sense / DUTGND 异常检测；
9. 芯片温度检测和 Thermal Shutdown；
10. Programmable Slew Rate；
11. FIN DAC Ramp；
12. DAC Offset/Gain Correction；
13. Force Amplifier Compensation；
14. 多颗器件 Gang；
15. Diagnostic 内部节点测量。

AD5560 **没有内部 ADC 把实际电压/电流直接转换为数字码**。实际测量值主要从模拟 `MEASOUT` 输出，再由系统外部 ADC 采样并送回 FPGA。

---

## 3. FPGA 控制时首先要理解的几个概念

### 3.1 Force 与 Measure 是两条不同路径

Force 路径负责输出：

```text
FIN DAC -> Force Amplifier -> FORCE -> DUT
```

Measure 路径负责观测：

```text
DUT / SENSE / Current Sense
        -> Measure MUX
        -> MEASOUT
        -> 外部 ADC
        -> FPGA
```

因此：

- 写 FIN DAC 只改变目标输出值；
- 选择 MEASOUT 不改变 Force DAC；
- FPGA 应分别维护 Force 配置和 Measure 配置。

### 3.2 Current Range 不只是“测量量程”

`DPS Register 1` 中的 `I[2:0]` 会选择实际工作的输出/测流通道。

| I[2:0] | Current Range |
|---:|---|
| 0 | ±5 µA |
| 1 | ±25 µA |
| 2 | ±250 µA |
| 3 | ±2.5 mA |
| 4 | ±25 mA |
| 5 | External Range 2，最高约 ±500 mA |
| 6 | External Range 1，最高约 ±1.2 A |
| 7 | Reserved |

前 5 档使用片内 Sense Resistor，高电流两档使用外部 Sense Resistor。

量程变化会同时影响：

- 实际输出路径；
- 电流测量换算；
- Comparator 阈值组；
- Clamp 和稳定性设计。

---

## 4. DAC 的 x1 / m / c / x2 结构

AD5560 中很多 DAC 都不是把 FPGA 写入的 16-bit code 直接送到模拟 DAC。

内部结构为：

```text
           m register
               |
x1 register ---+---> Calibration Engine ---> x2 ---> Resistor-String DAC
               |
           c register
```

其中：

- `x1`：FPGA 可以写入和读回的 16-bit 目标码；
- `m`：16-bit Gain Correction Register；
- `c`：16-bit Offset Correction Register；
- `x2`：Calibration Engine 计算出的内部 DAC data word；
- `x2` 最终加载到 resistor-string DAC；
- `x2` 不能通过 SPI Readback 直接读取。

数字传递关系为：

```text
x2 = x1 * (m + 1) / 2^16 + (c - 2^15)
```

默认值：

```text
m = 0xFFFF
c = 0x8000
```

此时理想情况下：

```text
x2 = x1
```

FIN、CLL、CLH 以及 Comparator DAC 等都采用类似的 `x1 / m / c` 结构，各 DAC 的校正寄存器彼此独立。

---

## 5. Calibration Engine 工作机理

本节只说明 AD5560 内部 Calibration Engine 如何工作，不讨论外部如何获取或计算校准系数。

### 5.1 Calibration Engine 的作用

Calibration Engine 位于 SPI 可见的 `x1/m/c` 寄存器和实际 DAC `x2` 之间。

FPGA 写入 DAC `x1` 后，AD5560 不会立即把 `x1` 原码送入 DAC，而是执行：

```text
Write x1
   |
   v
读取当前 x1、m、c
   |
   v
Calibration Engine
   |
   +--> Gain Correction
   +--> Offset Correction
   |
   v
生成 x2
   |
   v
加载到实际 DAC
```

因此 FPGA 看到的是“目标码 `x1`”，真正驱动模拟 DAC 的是内部 `x2`。

### 5.2 什么操作会启动 Calibration Engine

**对应 DAC 的 `x1` 写入会启动 Calibration Engine。**

每次新的 `x1` 写入完成后，AD5560 都会用当时保存的 `m`、`c` 重新计算 `x2`。

相反：

- 写 `m` 不启动 Calibration Engine；
- 写 `c` 不启动 Calibration Engine。

因此 `m/c` 寄存器更新本身只是改变后续校正运算使用的系数。

从器件机理上可以得到一个重要结论：

> 单独更新 `m/c` 并不会使当前已加载的 `x2` 自动重新计算。新的 `m/c` 会在下一次对应 `x1` 写入触发 Calibration Engine 时参与计算。

### 5.3 三阶段计算流水线

数据手册说明 `x2` 的计算采用三阶段过程：

```text
Stage 1 : 600 ns
Stage 2 : 600 ns
Stage 3 : 300 ns
------------------
总计算路径约 1.5 us
```

对应 SPI Timing Table 中，DAC `x1` write 的 `BUSY Low` 最大时间也是 **1.5 µs**。

普通非 DAC-x1 寄存器写的 `BUSY Low` 最大值约为 **280 ns**，因此 FPGA 需要区分普通寄存器写和 DAC `x1` 写的内部处理时间。

### 5.4 BUSY 与 Calibration Engine

当 Calibration Engine 计算 `x2` 时：

```text
x1 write complete
      |
      v
BUSY = 0
      |
Calibration Engine calculation
      |
      v
BUSY = 1
      |
      v
DAC output update
```

数据手册明确指出，DAC 输出在 `BUSY` 回到 High 后立即更新。

因此对于 FPGA：

> `BUSY` 不只是“SPI 收完了没有”，而是 AD5560 内部寄存器更新/Calibration Engine 是否已经完成的状态信号。

### 5.5 Calibration Engine 支持流水处理

Calibration Engine 是流水结构，不要求 FPGA 在每次 `x1` 写完后都空等完整 1.5 µs 才开始准备下一帧。

数据手册给出的关键约束是：

- 第一阶段计算需要 600 ns；
- 前一个 `x1` 写操作完成后，在第一阶段结束之前，下一个相关写操作不能完成；
- 也就是下一次写的 `SYNC` 上升沿不能早于上一笔 `x1` 写完成后的约 600 ns。

因此存在两种 FPGA 实现方式：

```text
简单模式：
write x1 -> wait BUSY high -> next write

高吞吐模式：
利用 600 ns pipeline update interval 调度连续 DAC 更新
```

第一版 RTL 推荐采用简单模式，确认功能后再做流水优化。

### 5.6 BUSY Low 期间其他寄存器写的约束

当 `BUSY=0` 时，串行接口并不是完全停止工作。

对于 Control Register、`m`、`c` 等写操作，可以开始把数据移入串行接口，但数据手册要求：

> 在 BUSY 回到 High 之前，不应通过 `SYNC` 上升沿完成这笔寄存器写入。

因此 FPGA SPI transaction controller 最简单可靠的策略仍然是：

```text
需要完成新寄存器写
        |
        +--> BUSY = 1 ?
                 |
              Yes
                 |
                 v
             完成写事务
```

### 5.7 x2 不可 Readback

FPGA 可以读取：

```text
x1
m
c
```

但不能直接读取内部：

```text
x2
```

所以 Readback 能确认的是“输入寄存器配置”，不能直接用 SPI 检查 Calibration Engine 最终得到的 x2 code。

### 5.8 Calibration Engine 与 LOAD

在使用 LOAD 功能时，Calibration Engine 可以先根据 `x1/m/c` 得到新的 `x2`，而实际 DAC 更新由 LOAD 机制控制。

LOAD 能控制的对象包括：

- FIN DAC x2；
- CLL DAC x2；
- CLH DAC x2；
- Compensation；
- Current Range。

因此需要区分：

```text
Calibration Engine
    -> 负责算出 x2

LOAD
    -> 负责什么时候把准备好的结果应用到输出/通道
```

### 5.9 Calibration Engine 与 Ramp

Ramp Function 同样使用 Calibration Engine。

Ramp 过程中：

```text
当前 FIN x1
    |
根据 Step Size 生成下一个 x1
    |
Calibration Engine
    |
生成校正后的下一步 x2
    |
RCLK / Divider 控制更新时刻
    |
FIN DAC 更新
```

数据手册说明 Ramp 中使用 Calibration Engine，并存在约 **1.2 µs** 的 calibration delay；下一步的校正计算可以在当前模拟输出建立期间进行。

这也是 Ramp 最大更新速率受到内部 Calibration Engine 限制的原因之一。

---

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

Readback 时由于 `SDO` 驱动较弱，最大 SCLK 与 DVCC 有关：

| DVCC | Readback 最大 SCLK |
|---|---:|
| 2.3 V ~ 2.7 V | 12 MHz |
| 2.7 V ~ 3.3 V | 15 MHz |
| 4.5 V ~ 5.5 V | 20 MHz |

FPGA 第一版建议先统一采用较低 SCLK，等读写时序稳定后再分别提高 write-only 事务速率。

### 6.2 24-bit 命令格式

每个命令固定 24 bit，MSB First：

```text
Bit23       Bit22 ........ Bit16   Bit15 ........ Bit0
+----+      +------------------+   +------------------+
|R/W |      | Address[6:0]     |   | Data[15:0]       |
+----+      +------------------+   +------------------+
```

即：

```text
frame[23]    = R/W
frame[22:16] = register address
frame[15:0]  = register data
```

FPGA 内部可以直接形成：

```text
spi_tx_data[23:0] = {rw, addr[6:0], data[15:0]}
```

### 6.3 写寄存器流程

```text
SYNC = 1
   |
SYNC = 0
   |
发送 24 bit
   |
SYNC = 1      <- 寄存器写入完成点
   |
等待 BUSY / 满足下一笔写时序
```

重要规则：

- `SYNC` 拉低开始一帧；
- 至少发送 24 个 SCLK；
- `SYNC` 上升沿完成输入寄存器更新；
- Reserved bit 按数据手册规定写 0；
- 涉及 DAC `x1` 时，需要考虑 Calibration Engine 的较长 BUSY。

### 6.4 BUSY

`BUSY` 为 Open-Drain、Active-Low。

典型含义：

```text
BUSY = 0 -> AD5560 内部仍在处理
BUSY = 1 -> 当前内部更新完成
```

主要时序量级：

- DAC `x1` write：BUSY Low 最大约 1.5 µs；
- 其他寄存器 write：BUSY Low 最大约 280 ns；
- RESET：Timing Table 给出的 BUSY Low 最大约 400 µs。

多颗 AD5560 的 BUSY 可以 wired-OR，但共享后只能知道“这一组中仍有器件忙”，不能直接知道是哪一颗。

### 6.5 RESET

`RESET` 是低有效、level-sensitive 输入。

典型 FPGA 控制流程：

```text
RESET = 0
   |
保持满足最小低脉宽
   |
RESET = 1
   |
等待 BUSY = 1
   |
开始 SPI 初始化
```

Reset 过程中不要完成新的 SPI 写事务。

### 6.6 Readback 是两帧

AD5560 读寄存器需要两次 SPI frame。

第一帧：Read Request

```text
R/W     = 1
Address = target register
Data    = 0x0000
```

第二帧：NOP，同时从 SDO 移出前一帧指定的寄存器数据。

```text
Frame 1:
SYNC low
Read(addr)
SYNC high

SYNC high >= 250 ns

Frame 2:
SYNC low
NOP
SDO -> receive data
SYNC high
```

因此 FPGA 读事务状态机至少要有：

```text
READ_REQUEST
WAIT_SYNC_HIGH
READBACK_NOP
DONE
```

注意：

- Readback SCLK 低于 write-only 最高频率；
- 两帧之间 `SYNC` High 至少 250 ns；
- `SDO` 在 `SYNC` High 后进入 High-Z；
- `0x43/0x44` 是只读状态寄存器；
- DAC `x2` 不可读回。

---

## 7. 主要寄存器总览

| 地址 | 名称 | 主要作用 |
|---:|---|---|
| `0x00` | NOP | Readback 第二帧常用 |
| `0x01` | System Control | 温度关断、MEASOUT Gain、PD、LOAD |
| `0x02` | DPS Register 1 | SW_INH、Current Range、Comparator、Measure、Clamp |
| `0x03` | DPS Register 2 | Slew Rate、GPO、Gang、System Force/Sense |
| `0x04` | Compensation Register 1 | Auto Compensation |
| `0x05` | Compensation Register 2 | Manual Compensation |
| `0x06` | Alarm Setup | Alarm latch / pin mask |
| `0x07` | Diagnostic | 内部节点诊断 |
| `0x08` | FIN DAC x1 | Force Voltage 目标码 |
| `0x09` | FIN DAC m | FIN Gain Correction |
| `0x0A` | FIN DAC c | FIN Offset Correction |
| `0x0B` | Offset DAC | DAC 总体偏置/输出范围 |
| `0x0C` | OSD DAC | FORCE-SENSE 开路检测阈值 |
| `0x0D~0x0F` | CLL x1/m/c | Low Current Clamp |
| `0x10~0x12` | CLH x1/m/c | High Current Clamp |
| `0x13~0x3C` | CPL/CPH DAC | 各 Current Range 的 Comparator 阈值及校正 |
| `0x3D` | DGS DAC | DUTGND Sense Alarm Threshold |
| `0x3E` | Ramp End Code | Ramp 终点 |
| `0x3F` | Ramp Step Size | Ramp 步长 |
| `0x40` | RCLK Divider | Ramp Clock 分频 |
| `0x41` | Enable Ramp | 写 `0xFFFF` 启动 Ramp |
| `0x42` | Interrupt Ramp | 写 `0x0000` 中断 Ramp |
| `0x43` | Alarm Status | 读告警，不清 Latched Alarm |
| `0x44` | Alarm + Clear | 读取并清 Latched Alarm |
| `0x45~0x4A` | VSENSE CPL/CPH | 电压比较器阈值及校正 |

---

## 8. System Control Register `0x01`

Power-On Default：`0x0000`。

### 8.1 TMP[1:0]

Bit `[15:14]`：

| TMP | Thermal Shutdown |
|---:|---:|
| 0 | 130°C，默认 |
| 1 | 120°C |
| 2 | 110°C |
| 3 | 100°C |

这是 AD5560 自身结温保护，不是 DUT 温度。

### 8.2 GAIN[1:0]

Bit `[13:12]`：

| GAIN[1:0] | MEASOUT Gain | MI Gain |
|---:|---:|---:|
| 0 | 1 | 20 |
| 1 | 1 | 10 |
| 2 | 0.2 | 20 |
| 3 | 0.2 | 10 |

### 8.3 FINGND

Bit 11：

- `0`：Force Amplifier 输入来自 Force DAC；
- `1`：Force Amplifier 正输入切到 GND。

正常可编程输出通常保持 `FINGND=0`。

### 8.4 CPO

Bit 10，用于选择 Comparator 输出组织方式，可减少返回 FPGA 的 Comparator 引脚数量。

### 8.5 PD

Bit 9：

```text
PD = 0 -> Force Amplifier Block Power-Down，默认
PD = 1 -> Force Amplifier Block Power-Up
```

它不是普通的 DUT 输出 Enable。若只是希望 FORCE High-Z，通常使用 `SW_INH/HW_INH`。

### 8.6 LOAD[1:0]

Bit `[8:7]`：

| LOAD | 行为 |
|---:|---|
| 0 | 默认，CLEN/HW_INH 保持原功能 |
| 1 | `CLEN` 引脚改作 LOAD |
| 2 | `HW_INH` 引脚改作 LOAD |
| 3 | 保留 CLEN/HW_INH 原功能，通过 BUSY 同步更新 |

LOAD 可控制：

- FIN DAC；
- CLL / CLH；
- Compensation；
- Current Range。

LOAD 不是 Ramp Start。

---

## 9. DPS Register 1 `0x02`

### 9.1 SW_INH

Bit 15：

```text
SW_INH = 0 -> Force Amplifier Disable
SW_INH = 1 -> 允许 Force Amplifier 工作的一个条件
```

与硬件 `HW_INH` 的关系：

```text
SW_INH = 1
    AND
HW_INH = 1
      |
      v
Force Amplifier Enable
```

因此：

- FIN DAC 写入和输出 Enable 是两个不同动作；
- FPGA 可用 `HW_INH` 做硬件级快速禁止；
- 也可通过 SPI 写 `SW_INH=0` 单独关闭器件。

### 9.2 I[2:0]：Current Range

Bit `[13:11]`，量程定义见第 3.2 节。

FPGA 改变量程后，要同步切换：

- 电流换算参数；
- Comparator Threshold 组；
- Clamp 相关配置；
- 必要的 Compensation。

### 9.3 CMP[1:0]

Bit `[10:9]`：

| CMP | 功能 |
|---:|---|
| 0/1 | Comparator Output High-Z |
| 2 | Compare DUT Current |
| 3 | Compare DUT Voltage |

### 9.4 ME[3:0]

Bit `[8:5]` 控制 MEASOUT。

典型选择包括：

```text
High-Z
ISENSE
VSENSE
KSENSE
TSENSE
DUTGND SENSE
DIAG A
DIAG B
```

### 9.5 CLEN

Bit 4，软件 Clamp Enable。

与硬件 `CLEN` 引脚为 OR 关系：

```text
Clamp Enable = SW_CLEN OR HW_CLEN
```

过流时 Clamp 是模拟级第一层保护。真正要把 DUT 隔离，应使用 `SW_INH/HW_INH`，而不是关闭 Clamp。

---

## 10. DPS Register 2 `0x03`

### 10.1 SR[2:0]：Programmable Slew Rate

Bit `[14:12]`：

| SR | Slew Rate |
|---:|---:|
| 0 | 1 V/µs |
| 1 | 0.875 V/µs |
| 2 | 0.75 V/µs |
| 3 | 0.625 V/µs |
| 4 | 0.5 V/µs |
| 5 | 0.4375 V/µs |
| 6 | 0.35 V/µs |
| 7 | 0.3125 V/µs |

Slew Rate 是模拟输出变化速度控制，不是 DAC code 逐级变化的 Ramp Function。

### 10.2 GPO

GPO 可驱动外部辅助开关，例如 DUT 端电容切换等。

### 10.3 Gang Mode

用于多颗 AD5560 并联以获得更高电流，可配置 Master / Slave 等模式。单器件第一版建议保持默认。

### 10.4 INT10K

可在 FORCE 与 SENSE 之间接入片内约 10 kΩ 通路。正常 Kelvin 工作时不要无目的开启。

### 10.5 Guard High-Z

用于将 Guard Amplifier 置 High-Z；当 `GUARD/SYS_DUTGND` 复用为 System DUTGND 时需要正确配置。

---

## 11. Force Voltage：FIN DAC

关键寄存器：

```text
0x08 FIN DAC x1
0x09 FIN DAC m
0x0A FIN DAC c
0x0B Offset DAC
```

正常运行时最频繁写的是 `0x08`。

对于 5 V VREF，Force/Comparator DAC 总 span 约 25.625 V。默认 Offset DAC 为 `0x8000` 时，中码附近约对应 0 V：

```text
FIN DAC = 0x8000 -> 约 0 V，相对于 DUTGND
```

默认 m/c 下可近似理解为：

```text
Vout ≈ 25.625 V * (code - 32768) / 65536 + DUTGND
```

实际输出还与以下因素有关：

- VREF；
- Offset DAC；
- m/c 与 Calibration Engine；
- AVDD/AVSS、HCAVDD/HCAVSS headroom；
- DUTGND；
- 外部高电流 Rsense 和线路压降。

FPGA 内部建议把“物理电压参数”和“FIN code”分开，不要让上层控制状态机直接散落裸 DAC code。

---

## 12. Current Clamp

Clamp 用于限制 DUT source/sink 电流。

### 12.1 寄存器

```text
0x0D CLL DAC x1
0x0E CLL DAC m
0x0F CLL DAC c

0x10 CLH DAC x1
0x11 CLH DAC m
0x12 CLH DAC c
```

- `CLL`：Low Clamp；
- `CLH`：High Clamp。

### 12.2 CLALM

实际输出进入 Clamp 状态时会触发 `CLALM`。

```text
DUT 电流试图超过 Clamp
        |
        v
AD5560 模拟 Clamp 介入
        |
        +--> 电流被限制
        |
        +--> CLALM
                |
                v
              FPGA
                |
          读 0x43 定位
                |
      SW_INH/HW_INH 隔离
```

Clamp 可以承担第一层快速保护，但不应把持续 Clamp 当作长期正常工作状态。

---

## 13. Comparator

AD5560 内置电流/电压 Comparator，可在不经过 ADC 的情况下做窗口判断。

FPGA 配置逻辑包括：

1. `CMP[1:0]` 选择电流或电压；
2. 写 Low Threshold；
3. 写 High Threshold；
4. 使用 `CPOL/CPOH` 硬件输出，或读取 `0x43/0x44` 中状态。

### 13.1 电流 Comparator

每个 Current Range 有独立的 CPL / CPH DAC 组。

| Range | CPL x1 | CPH x1 |
|---|---:|---:|
| ±5 µA | `0x13` | `0x28` |
| ±25 µA | `0x16` | `0x2B` |
| ±250 µA | `0x19` | `0x2E` |
| ±2.5 mA | `0x1C` | `0x31` |
| ±25 mA | `0x1F` | `0x34` |
| EXT Range 2 | `0x22` | `0x37` |
| EXT Range 1 | `0x25` | `0x3A` |

每个 `x1` 后都有对应独立 `m/c`。

### 13.2 电压 Comparator

```text
0x45 CPL DAC x1
0x46 CPL DAC m
0x47 CPL DAC c

0x48 CPH DAC x1
0x49 CPH DAC m
0x4A CPH DAC c
```

Comparator 更适合快速 Pass/Fail；精确数值测量仍走 `MEASOUT + ADC`。

---

## 14. MEASOUT 与外部 ADC

AD5560 的实际测量结果主要从模拟 `MEASOUT` 输出。

可以选择：

- DUT Current；
- DUT Voltage；
- Kelvin Sense；
- Die Temperature；
- DUTGND Sense；
- Diagnostic Nodes。

### 14.1 电流测量链

```text
Current Range
      |
      v
Current Sense / MI Gain
      |
      v
MEASOUT Gain
      |
      v
MEASOUT
      |
      v
External ADC
      |
      v
FPGA
```

换算依赖：

- Current Range；
- Rsense；
- MI Gain = 10 / 20；
- MEASOUT Gain = 1 / 0.2；
- 外部 ADC 量程及系统参数。

因此 FPGA 侧应根据当前量程选择对应的换算参数，而不是所有量程共用一个系数。

### 14.2 电压测量链

```text
DPS1.ME -> VSENSE
       |
等待 MEASOUT 建立
       |
External ADC sample
       |
FPGA 换算实际电压
```

---

## 15. Alarm 系统

主要有三个 Open-Drain、Active-Low 告警引脚：

```text
CLALM  -> Current Clamp Alarm
KELALM -> Kelvin 综合 Alarm
TMPALM -> Temperature Alarm
```

`KELALM` 内部可以由：

- `OSALM`：Open-Sense / FORCE-SENSE 异常；
- `DUTALM`：DUTGND Kelvin 异常；
- `GRDALM`：Guard Alarm；

共同产生。

多个 AD5560 的 Alarm 可以 wired-OR，再由 FPGA 通过独立 `SYNC` 扫描各器件 `0x43` 定位。

---

## 16. Alarm Setup Register `0x06`

可以控制各 Alarm：

- 是否映射到外部告警 pin；
- 是否 Latched。

| Bit | 功能 |
|---:|---|
| 15 | Latched TMPALM |
| 14 | Disable TMPALM pin flag |
| 13 | Latched OSALM |
| 12 | Disable OSALM pin flag |
| 11 | Latched DUTALM |
| 10 | Disable DUTALM pin flag |
| 9 | Latched CLALM |
| 8 | Disable CLALM pin flag |
| 7 | Latched GRDALM |
| 6 | Disable GRDALM pin flag |

即使某类 Alarm 不输出到硬件 pin，其状态仍可以从 `0x43/0x44` 读取。

多通道系统通常适合关键告警使用 Latched 模式，以免窄脉冲在 FPGA 扫描之前消失。

---

## 17. Alarm Status `0x43 / 0x44`

### 17.1 `0x43`

读取状态，不清 Latched Alarm。

| Bit | 名称 |
|---:|---|
| 15 | LTMPALM |
| 14 | TMPALM |
| 13 | LOSALM |
| 12 | OSALM |
| 11 | LDUTALM |
| 10 | DUTALM |
| 9 | LCLALM |
| 8 | CLALM |
| 7 | LGRDALM |
| 6 | GRDALM |
| 5 | CPOL |
| 4 | CPOH |

Alarm bit 是 Active-Low 语义：

```text
LCLALM = 0 -> 曾发生 Clamp Alarm
CLALM  = 0 -> 当前 Clamp Alarm 仍存在
```

### 17.2 `0x44`

读取状态并清除 Latched Alarm。

推荐 FPGA 故障流程：

```text
ALARM_N low
    |
    v
扫描器件并读取 0x43
    |
    v
锁存 channel + fault type
    |
    v
执行保护/隔离
    |
    v
需要清故障时读取 0x44
```

不要一进入故障就先读 `0x44`，否则读取和清除动作会混在一起。

---

## 18. Kelvin / Open-Sense 保护

### 18.1 OSD DAC `0x0C`

OSD 用于设置 FORCE 与 SENSE 之间允许的差值。

当：

```text
|FORCE - SENSE| > OSD threshold
```

可能触发 `OSALM -> KELALM`。

Sense 开路时 Force 闭环已经不可信，因此这是 Wafer Test 中很重要的接触/回路异常检测。

### 18.2 DGS DAC `0x3D`

用于设置 DUTGND 与 AGND 之间的异常阈值，对应 `DUTALM/KELALM`。

---

## 19. 温度检测与 Thermal Shutdown

AD5560 内部同时具有：

- Thermal Shutdown 温度检测；
- 可通过 `MEASOUT` 读取的 TSENSE；
- Diagnostic 中可选择的片上热二极管。

Thermal Shutdown 触发后，AD5560 会自动禁止 Force Amplifier。

因此 TMPALM 更接近最后一级器件自保护，而不是正常运行时的温度调节环路。

---

## 20. Compensation

Force Amplifier 为了适应不同 DUT 电容和 ESR，需要配置补偿。

主要有：

1. Safe Mode；
2. Auto Compensation；
3. Manual Compensation。

### 20.1 Safe Mode

Power-On 默认采用安全补偿状态，稳定性优先，但动态响应较慢。

### 20.2 Auto Compensation `0x04`

FPGA 配置 DUT 的大致：

```text
CDUT
ESR
```

AD5560 根据寄存器选择内部补偿组合。

数据手册特别提醒：

- 高估 CDUT 可能造成不稳定；
- 低估 ESR 可能造成不稳定；
- 反方向误差通常更偏向响应变慢。

### 20.3 Manual Compensation `0x05`

可以直接配置内部 gm、RP、RZ、CF、CC 等补偿参数。

这部分更适合环路调试阶段，正常业务状态机不应频繁修改。

---

## 21. Slew Rate 与 Ramp Function

两者不能混淆。

### 21.1 Slew Rate

由 `DPS Register 2.SR[2:0]` 控制。

特点：

- FIN DAC 目标可以一步写到最终 code；
- Force 路径以设定速度追目标；
- 适合 µs 级输出边沿控制。

### 21.2 Ramp Function

Ramp 是 FIN DAC `x1` 本身按步进变化。

```text
0x08 -> 当前 FIN x1，同时作为 Ramp Start
0x3E -> Ramp End Code
0x3F -> Ramp Step Size
0x40 -> RCLK Divider
0x41 -> 0xFFFF，Enable Ramp
0x42 -> 0x0000，Interrupt Ramp
```

Step Size 为 16 LSB 的整数倍。

RCLK Divider：

```text
/1 ... /255
```

Divider=1 时，数据手册给出的 RCLK 最大约 833 kHz。

Ramp 期间普通 SPI 命令会被忽略，接口只接受 Interrupt Ramp，因此 Ramp Start 前必须先完成其他配置。

更详细的上电顺序见 [`AD5560_CONTROL.md`](./AD5560_CONTROL.md)。

---

## 22. LOAD 与多器件同步

AD5560 没有独立 LOAD pin，可以把：

- `CLEN`；或
- `HW_INH`

复用为 LOAD。

LOAD 可同步：

- FIN DAC x2；
- Clamp DAC x2；
- Current Range；
- Compensation。

如果系统还需要独立快速 `HW_INH`，通常更适合保留 `HW_INH` 原功能，将 `CLEN` 复用为 LOAD，Clamp Enable 由寄存器控制。

`LOAD=3` 模式还可以通过共享 BUSY 实现多通道同步更新，而不占用 CLEN/HW_INH 的原功能。

---

## 23. Diagnostic Register `0x07`

Diagnostic 可以把许多内部节点送到 `MEASOUT`，包括：

- Force Amplifier 内部节点；
- EXTFORCE 输出级；
- FINP / FINM；
- Measure Block；
- DAC 内部节点；
- Clamp / Comparator DAC；
- OSD / DGS DAC；
- 多处片上温度二极管；
- 高电流输出级分段诊断。

FPGA 第一版可以暂时不用 Diagnostic，但底层寄存器驱动应允许读写 `0x07`，便于后续板卡自检和硬件调试。

---

## 24. FPGA 推荐初始化流程

```text
POWER ON
   |
   v
等待 BUSY = 1
   |
   v
必要时 RESET
   |
   v
等待 BUSY = 1
   |
   v
保持 HW_INH = 0
   |
   v
System Control
  - PD = 1
  - GAIN
  - TMP threshold
  - LOAD mode
   |
   v
DPS Register 2
  - Slew Rate
  - Gang / System Force-Sense
   |
   v
Compensation
   |
   v
Alarm Setup
   |
   v
OSD / DGS
   |
   v
DPS Register 1
  - Current Range
  - Clamp Enable
  - Measure mode
  - SW_INH = 0
   |
   v
CLL / CLH
Comparator Threshold
   |
   v
FIN DAC = safe start value
   |
   v
可选 Readback 验证
   |
   v
SW_INH = 1
   |
   v
根据系统时序释放 HW_INH
或启动 Ramp
   |
   v
RUN
```

第一版 FPGA 控制建议采用保守策略：

```text
write transaction
    -> wait BUSY high
    -> next dependent transaction
```

后续再根据 Calibration Engine 的 600 ns pipeline interval 优化连续 DAC 更新。

---

## 25. FPGA 推荐运行状态机

```text
IDLE / HIGH-Z
    |
    +--> CONFIG
    |      +--> voltage
    |      +--> current range
    |      +--> clamp
    |      +--> compensation
    |      +--> alarm
    |
    +--> ENABLE
    |      +--> SW_INH/HW_INH
    |      +--> optional Ramp
    |
    +--> RUN
    |      +--> MEASOUT select
    |      +--> external ADC sample
    |      +--> status monitor
    |
    +--> FAULT
           +--> scan 0x43
           +--> latch channel/type
           +--> SW_INH=0 or HW_INH=0
           +--> read 0x44 when clear is allowed
```

---

## 26. 多颗 AD5560 的 FPGA 接口建议

AD5560 SPI 命令中没有器件地址，因此多颗器件必须依赖外部 `SYNC` 选择，或使用 Daisy Chain。

FPGA 多通道设计建议：

```text
SCLK  -> Shared
SDI   -> Shared
SYNC  -> 每颗逻辑独立，可由 FPGA + Decoder 产生
SDO   -> Shared 或分组共享
BUSY  -> Shared / 分组 wired-OR
ALARM -> Shared / 分组 wired-OR
RESET -> Shared / 分组
RCLK  -> Shared
HW_INH-> 根据实际需要独立或分组
```

其中：

- `SYNC` 最重要的是“逻辑上能单颗寻址”，不要求 FPGA 必须直接占用 N 个 IO；
- `SDO` 未选中时 High-Z，因此可以共享，但器件很多时要考虑总线电容和 SDO 驱动能力；
- Alarm 共享后通过 SPI 扫描 `0x43` 定位器件；
- BUSY 共享后只能得到组级 Busy 状态。

---

## 27. FPGA 推荐模块划分

不使用 MCU/DSP 风格的函数 API，建议在 RTL 中至少拆成以下几层。

### 27.1 SPI Physical / Shift Engine

只负责引脚时序：

```text
SCLK
SDI
SDO
SYNC
24-bit shift
```

对上提供类似事务接口：

```text
req_valid
req_ready
req_dev
req_rw
req_addr[6:0]
req_wdata[15:0]

rsp_valid
rsp_rdata[15:0]
rsp_error
```

具体信号命名可按项目规范调整，关键是上层不直接操作 SCLK bit timing。

### 27.2 AD5560 Transaction Controller

负责器件级事务：

- 选择目标 `SYNC`；
- 普通 Write；
- 两帧 Readback；
- Readback 的 250 ns SYNC High；
- BUSY 等待；
- RESET 流程；
- DAC `x1` 和普通寄存器的不同 update timing。

### 27.3 Register / Channel Configuration Layer

维护：

- System Control；
- DPS1 / DPS2；
- Alarm；
- Compensation；
- 每通道 Current Range；
- FIN / Clamp / Comparator 参数；
- 必要的 Shadow Register。

使用 Shadow Register 可以避免修改某一 bit 时破坏同一寄存器的其他字段。

### 27.4 Function Sequencer

实现：

- 初始化；
- 设置电压；
- 量程切换；
- Clamp；
- MEASOUT 选择；
- 上下电；
- Ramp；
- Alarm 扫描与关断。

上位机或项目应用模块只给出物理参数和动作请求，不直接关心 SPI bit timing。

---

## 28. 第一阶段建议实现的最小功能集

### SPI / Transaction

- 单颗逻辑 `SYNC` 选择；
- 24-bit Write；
- 两帧 Readback；
- BUSY wait；
- RESET。

### 基础寄存器

- `0x01` System Control；
- `0x02` DPS Register 1；
- `0x03` DPS Register 2；
- `0x04` Compensation 1；
- `0x06` Alarm Setup；
- `0x08` FIN DAC；
- `0x0C` OSD；
- `0x0D/0x10` CLL/CLH；
- `0x3D` DGS；
- `0x43/0x44` Alarm；
- `0x3E~0x42` Ramp。

### 基础动作

- 初始化；
- 设置 Force Voltage；
- 设置 Current Range；
- 设置 Clamp；
- Enable / Disable Output；
- MEASOUT 选择；
- Alarm Read/Clear；
- Ramp。

Comparator、Gang、Diagnostic、Manual Compensation 和复杂连续 DAC 更新可以第二阶段加入。

---

## 29. FPGA 实现中特别容易踩坑的点

### 29.1 `PD=0` 是 Power-Down

不要按名字直觉把 `PD` 当 Enable。

### 29.2 `SW_INH=1` 才是允许输出

并且必须同时满足 `HW_INH=1`。

### 29.3 Alarm Status 是 Active-Low

```text
0 = Alarm
1 = No Alarm
```

建议 FPGA 状态解析层立即转换成内部正逻辑 fault flags。

### 29.4 `0x44` 会清 Latched Alarm

先用 `0x43` 诊断，再决定何时读 `0x44`。

### 29.5 Readback 是两帧

第一帧指定地址，第二帧 NOP 才得到数据。

### 29.6 Readback SCLK 低于 Write SCLK

不要把 50 MHz write-only 时钟直接当成 Readback 时钟。

### 29.7 DAC `x1` 写会进入 Calibration Engine

BUSY 最大时间约 1.5 µs，并且内部是 600 ns / 600 ns / 300 ns 三阶段流水。

### 29.8 写 `m/c` 不会自动刷新当前 DAC 输出

`m/c` 写本身不启动 Calibration Engine；新的系数要等下一次相应 `x1` 写触发 `x2` 重算后才进入实际 DAC 数据路径。

### 29.9 MEASOUT 需要外部 ADC

不能通过读 AD5560 寄存器直接得到实际 DUT 电压/电流数值。

### 29.10 Current Range 改变后相关参数必须同步

量程、测量换算、Comparator 和 Clamp 都有关联。

### 29.11 Compensation 不能忽略

高电流和大 DUT 电容下，补偿直接影响稳定性、过冲和建立时间。

---

## 30. Datasheet 推荐阅读顺序

如果主要做 FPGA 驱动和寄存器控制，可以按以下顺序阅读 Rev.F：

1. Page 1 ~ 3：Features / Functional Block Diagram；
2. Page 16 ~ 19：Pin Description；
3. Page 29 ~ 35：Force、Measure、Clamp、Current Range、Temperature；
4. Page 36 ~ 39：Compensation；
5. Page 40 ~ 42：DAC Levels、Offset/Gain Register、Calibration Engine 相关结构；
6. Page 43 ~ 44：Slew Rate / Ramp；
7. Page 45 ~ 46：Serial Interface、BUSY、LOAD、Register Update Rates；
8. Page 47 ~ 57：寄存器定义；
9. Page 57 ~ 58：Readback / Power-On Default；
10. Page 59 以后：Power Supply、外围、Layout、Thermal。

对 FPGA 控制来说，**Page 41、45、46、47~58** 尤其重要。

---

## 31. 后续可继续拆分的文档

后续如果进入正式 RTL 开发，可进一步拆分：

1. `AD5560_REGISTER_MAP.md`
   - 完整寄存器 bit 定义；
   - mask / shift；
   - reset value；
   - RW 属性。

2. `AD5560_CONVERSION.md`
   - Voltage ↔ FIN code；
   - Current ↔ MEASOUT；
   - Clamp ↔ DAC code；
   - Comparator ↔ DAC code。

3. `AD5560_DRIVER_DESIGN.md`
   - FPGA SPI 状态机；
   - 多通道 SYNC；
   - BUSY 调度；
   - Readback；
   - Alarm 扫描；
   - Register Shadow。

4. `AD5560_POWER_SEQUENCE.md`
   - DUT 上电；
   - Ramp；
   - 下电；
   - Fault 关断。

现有 `AD5560_CONTROL.md` 已覆盖第 4 项的一部分。

---

## 32. 官方参考资料

### AD5560 Rev.F Data Sheet

https://www.analog.com/media/en/technical-documentation/data-sheets/AD5560.pdf

本文的寄存器地址、位定义、SPI 时序、Calibration Engine 和主要器件行为均以该版本为主要依据。

### AD5560 Product Page

https://www.analog.com/en/products/ad5560.html

### AD5560 Evaluation Board User Guide

https://wiki.analog.com/resources/eval/ad5560_user_guide

### AN-2507：Integrated Device Power Supply (DPS) for ATE

https://www.analog.com/en/resources/app-notes/an-2507.html

---

## 33. 总结

从 FPGA 角度，AD5560 不是单纯的“SPI DAC”，而是一套完整 DPS：

```text
FPGA
 |
 +-- SPI Transaction ------> Register Control
 |
 +-- FIN x1/m/c -----------> Calibration Engine -> x2 -> Force DAC
 |
 +-- Current Range --------> Output / Measure Path
 |
 +-- CLL / CLH ------------> Current Clamp
 |
 +-- CPL / CPH ------------> Comparator
 |
 +-- ME MUX ---------------> MEASOUT -> ADC -> FPGA
 |
 +-- OSD / DGS ------------> Kelvin Protection
 |
 +-- Compensation ---------> Force Loop Stability
 |
 +-- Alarm ----------------> Fault Detect
 |
 +-- Slew / Ramp ----------> Power Sequence
```

其中 Calibration Engine 是理解 DAC 寄存器行为的关键：

```text
x1 写入
  -> 使用当前 m/c 计算 x2
  -> BUSY Low
  -> 三阶段流水计算
  -> BUSY High
  -> DAC 更新
```

而 `m/c` 写入本身不触发这条计算链。

第一版 RTL 建议先把 **SPI、BUSY、Readback、RESET、SW_INH、FIN DAC、Alarm** 跑通，再逐步加入 Measure、Clamp、Compensation、Ramp 和高吞吐 DAC 更新。