# AD5560 FPGA 控制与寄存器使用指南

## 1. 文档目的

本文面向使用 FPGA 控制 AD5560 的开发人员，从“如何通过数字接口控制器件”的角度整理 AD5560 Rev.F 数据手册中的主要内容。

重点包括：

- AD5560 能完成哪些功能；
- SPI 通信格式、寄存器写入和 Readback；
- `RESET`、`BUSY`、`SYNC`、`SDO` 等数字接口；
- 主要控制寄存器的作用；
- Force Voltage、Current Range、Measure、Clamp、Comparator；
- `FORCE/EXTFORCE`、`SENSE`、`DUTGND`、`SYS_FORCE/SYS_SENSE` 等引脚的区别；
- `GPO` 普通输出功能以及通过 GPO 引出片上热二极管的测温功能；
- `SW_INH` / `HW_INH` 与输出使能；
- Alarm 配置、故障读取与清除；
- Slew Rate 和 Ramp Function；
- Calibration Engine 的内部工作机制；
- Compensation、LOAD、Diagnostic 等功能；
- FPGA 侧推荐的模块划分和控制流程。

本文主要依据 Analog Devices **AD5560 Rev.F Data Sheet** 整理。模拟外围、电源轨、PCB、散热和外部补偿元件等仍应以原始数据手册为最终依据。

> 本文重点是 AD5560 自身机理和 FPGA 控制接口。已有的 [`AD5560_CONTROL.md`](./AD5560_CONTROL.md) 更侧重 DUT 上下电、`SW_INH/HW_INH`、Slew Rate、Ramp 和 LOAD 时序。

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
10. 片上多点 Thermal Diode Array；
11. Programmable Slew Rate；
12. FIN DAC Ramp；
13. DAC Offset/Gain Correction；
14. Force Amplifier Compensation；
15. 多颗器件 Gang；
16. Diagnostic 内部节点测量。

AD5560 **没有内部 ADC 把实际电压/电流直接转换为数字码**。实际测量值主要从模拟 `MEASOUT` 输出，再由系统外部 ADC 采样并送回 FPGA。

---

## 3. FPGA 控制时首先要理解的几个概念

### 3.1 Force 与 Measure 是两条不同路径

Force 路径负责输出：

```text
FIN DAC -> Force Amplifier -> FORCE / EXTFORCE -> DUT
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

FPGA 写入 DAC `x1` 后，AD5560 执行：

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

因此 FPGA 看到的是目标码 `x1`，真正驱动模拟 DAC 的是内部 `x2`。

### 5.2 什么操作会启动 Calibration Engine

**对应 DAC 的 `x1` 写入会启动 Calibration Engine。**

相反：

- 写 `m` 不启动 Calibration Engine；
- 写 `c` 不启动 Calibration Engine。

因此：

> 单独更新 `m/c` 并不会使当前已加载的 `x2` 自动重新计算。新的 `m/c` 会在下一次对应 `x1` 写入时参与计算。

### 5.3 三阶段计算流水线

数据手册给出的计算过程为：

```text
Stage 1 : 600 ns
Stage 2 : 600 ns
Stage 3 : 300 ns
------------------
总计算路径约 1.5 us
```

对应 DAC `x1` write 的 `BUSY Low` 最大时间约 **1.5 µs**；普通非 DAC-x1 寄存器写的 `BUSY Low` 最大值约 **280 ns**。

### 5.4 BUSY 与 Calibration Engine

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

`BUSY` 表示的不只是 SPI 是否收完，而是 AD5560 内部更新是否完成。

### 5.5 流水处理

Calibration Engine 是流水结构。第一阶段需要约 600 ns，因此可以比 1.5 µs 更高频地调度连续 DAC 更新，但第一版 RTL 建议采用：

```text
write x1 -> wait BUSY high -> next write
```

确认功能后再利用 pipeline interval 优化。

### 5.6 BUSY Low 期间其他写操作

当 `BUSY=0` 时可以开始移入下一帧数据，但不应在 BUSY 回到 High 之前通过 `SYNC` 上升沿完成新的相关寄存器写入。

### 5.7 x2 不可 Readback

FPGA 可以读取 `x1/m/c`，但不能直接读取内部 `x2`。

### 5.8 Calibration Engine 与 LOAD

```text
Calibration Engine
    -> 负责根据 x1/m/c 算出 x2

LOAD
    -> 负责准备好的 x2 / Range / Compensation 何时真正生效
```

LOAD 能控制的对象包括 FIN、CLL、CLH 的 DAC x2，以及 Compensation、Current Range。

### 5.9 Calibration Engine 与 Ramp

Ramp Function 同样经过 Calibration Engine：

```text
当前 FIN x1
    |
Step 生成下一个 x1
    |
Calibration Engine
    |
生成新的 x2
    |
RCLK / Divider
    |
FIN DAC 更新
```

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

FPGA 内部可形成：

```text
spi_tx_data[23:0] = {rw, addr[6:0], data[15:0]}
```

### 6.3 写寄存器流程

```text
SYNC = 0
   |
发送 24 bit
   |
SYNC = 1      <- 寄存器写入完成点
   |
等待 BUSY / 满足下一笔写时序
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

### 6.5 RESET

典型流程：

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

### 6.6 Readback 是两帧

第一帧发送 Read Request，第二帧发送 NOP 并从 SDO 接收结果：

```text
Frame 1: Read(addr)
SYNC high >= 250 ns
Frame 2: NOP + SDO readback
```

FPGA 读事务状态机至少需要：

```text
READ_REQUEST
WAIT_SYNC_HIGH
READBACK_NOP
DONE
```

DAC `x2` 不支持 Readback。

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
| `0x07` | Diagnostic | 内部节点诊断、片上 Thermal Diode 选择 |
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

### 8.4 CPO

Bit 10，用于选择 Comparator 输出组织方式。

### 8.5 PD

Bit 9：

```text
PD = 0 -> Force Amplifier Block Power-Down，默认
PD = 1 -> Force Amplifier Block Power-Up
```

它不是普通 DUT 输出 Enable；输出 High-Z 通常由 `SW_INH/HW_INH` 实现。

### 8.6 LOAD[1:0]

Bit `[8:7]`：

| LOAD | 行为 |
|---:|---|
| 0 | 默认，CLEN/HW_INH 保持原功能 |
| 1 | `CLEN` 引脚改作 LOAD |
| 2 | `HW_INH` 引脚改作 LOAD |
| 3 | 保留 CLEN/HW_INH 原功能，通过 BUSY 同步更新 |

LOAD 可控制 FIN、CLL/CLH、Compensation、Current Range 的实际更新。LOAD 不是 Ramp Start。

---

## 9. DPS Register 1 `0x02`

### 9.1 SW_INH

Bit 15：

```text
SW_INH = 0 -> Force Amplifier Disable
SW_INH = 1 -> 允许 Force Amplifier 工作的一个条件
```

与 `HW_INH` 为 AND 关系。

### 9.2 I[2:0]：Current Range

Bit `[13:11]`，定义见第 3.2 节。

### 9.3 CMP[1:0]

Bit `[10:9]`：

| CMP | 功能 |
|---:|---|
| 0/1 | Comparator Output High-Z |
| 2 | Compare DUT Current |
| 3 | Compare DUT Voltage |

### 9.4 ME[3:0]

Bit `[8:5]` 控制 MEASOUT，可选择 High-Z、ISENSE、VSENSE、KSENSE、TSENSE、DUTGND SENSE、DIAG A、DIAG B。

### 9.5 CLEN

Bit 4，软件 Clamp Enable，与硬件 CLEN 为 OR 关系：

```text
Clamp Enable = SW_CLEN OR HW_CLEN
```

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

### 10.2 GPO：普通数字输出

Bit 11 是 `GPO` 控制位。

在没有通过 Diagnostic Register 选择片上 Thermal Diode 时，GPO 可以作为普通的可控数字输出，例如控制 DUT 端模拟开关、去耦电容切换等外部功能。

```text
FPGA
  |
SPI 写 DPS Register 2.GPO
  |
  v
GPO pin -> 外部开关/控制逻辑
```

### 10.3 GPO：片上 Thermal Diode 输出

GPO 还有一个与普通数字输出完全不同的复用功能：

> Diagnostic Register `0x07` 可以选择 AD5560 die 上不同位置的 Thermal Diode。选中后，该二极管的 **D+ / 阳极连接到 GPO pin，D− / 阴极连接到 AGND**。

因此可以连接外部 Remote Diode Temperature Monitor，例如 ADI 评估板使用的 ADT7461：

```text
AD5560                         ADT7461

内部 Thermal Diode
      anode ---- GPO --------> D+
      cathode --- AGND ------> D-
```

此时 GPO 不再按 `DPS Register 2.GPO` bit 作为普通数字输出使用，而是作为模拟 PN 结温度传感器端口。

Thermal Diode 的具体选择由 `Diagnostic Register 0x07` 的 `TSENSE Select` 字段完成，详见第 23 节。

恢复普通 GPO 功能时，将 `TSENSE Select` 设回 `0~7` 中的正常 GPO 状态（通常使用 0），再由 `DPS Register 2` Bit11 控制 GPO。

### 10.4 Gang Mode

Bit `[10:9]` 用于多颗 AD5560 Gang，可配置 Master/Slave 以及 FV/FI 跟随方式。

### 10.5 INT10K

Bit 8 可以在 FORCE 与 SENSE 之间接入内部约 10 kΩ 通路。正常 Kelvin 测量时不要无目的开启。

### 10.6 SF0 与 Guard High-Z：System Force/Sense 连接

Bit15 `SF0` 和 Bit7 `Guard High-Z` 共同控制 `SYS_FORCE`、`SYS_SENSE`、`GUARD/SYS_DUTGND` 的内部开关：

| Guard High-Z | SF0 | SYS_SENSE | SYS_FORCE | GUARD/SYS_DUTGND |
|---:|---:|---|---|---|
| 0 | 0 | Open | Open | Guard |
| 0 | 1 | SENSE | FORCE | Guard |
| 1 | 0 | Open | Open | Open |
| 1 | 1 | SENSE | FORCE | DUTGND |

这些 System 引脚主要用于把中央 PMU/SMU 接入本通道做系统级校准或额外测量。普通独立 DPS 运行不需要使用它们。

---

## 11. FORCE / EXTFORCE / SENSE / DUTGND 等引脚

这几个引脚功能不同，不能简单理解成“只接 FORCE 和 SENSE 就够了”。

### 11.1 FORCE

`FORCE` 是 **片内五档电流量程**的 Force 输出：

```text
±5 µA
±25 µA
±250 µA
±2.5 mA
±25 mA
      -> FORCE
```

因此如果实际 DUT 电流超过 25 mA，不使用 FORCE 作为主功率输出，而应使用 EXTFORCE1 / EXTFORCE2。

### 11.2 EXTFORCE1 / EXTFORCE2

两档外部高电流输出：

```text
EXTFORCE1 -> 最大约 ±1.2 A
EXTFORCE2 -> 最大约 ±500 mA
```

高电流档需要配合外部 Sense Resistor 和对应的外部测流引脚。

### 11.3 SENSE

`SENSE` 是 DUT 电压 Kelvin Sense 输入。

```text
FORCE / EXTFORCE --------> DUT VDD
                              |
SENSE ------------------------+
```

Force 负责输送电流，SENSE 负责反馈 DUT 端实际电压，从而补偿 Force 路径上的线损。

`SENSE` 对内部电流档和外部高电流档都是关键反馈节点。

### 11.4 DUTGND

`DUTGND` 表示 DUT 实际地电位，是 AD5560 的 DUT Ground Reference / Kelvin Ground 节点，而不是简单等同于板上的 AGND。

对于远端 DUT、Probe Card、较大电流回路，应考虑 DUTGND 走线压降及 DUTGND Kelvin Alarm。

### 11.5 SYS_FORCE / SYS_SENSE

- `SYS_FORCE`：外部 System PMU 的 Force 信号输入；
- `SYS_SENSE`：把本通道 SENSE 节点送给外部 System PMU。

它们通过 `DPS Register 2.SF0` 控制内部开关，用于系统 PMU 校准和额外测量。普通 DUT 供电不需要它们。

### 11.6 GUARD / SYS_DUTGND

`GUARD/SYS_DUTGND` 为复用引脚：

- Guard 模式：Guard Amplifier 输出，用于高阻/低电流测量时驱动线缆屏蔽层，减小绝缘漏电；
- SYS_DUTGND 模式：把 DUTGND 节点送到 System PMU。

使用 SYS_DUTGND 时必须把 Guard Amplifier 设置为 High-Z。

### 11.7 MASTER_OUT / SLAVE_IN

用于多颗 AD5560 Gang，不是普通单颗 DUT 供电必需信号。

根据 Gang 模式，`MASTER_OUT` 可以输出 Master 的 Force Amplifier 控制信号，或者 Master 的 MI（测得电流）信号，供 Slave 的 `SLAVE_IN` 跟随。

### 11.8 普通独立通道通常关注哪些引脚

低电流档：

```text
FORCE + SENSE + DUTGND
```

高电流档：

```text
EXTFORCE1/2
+ SENSE
+ DUTGND
+ 外部 Rsense / EXTMEAS 引脚
```

`SYS_FORCE/SYS_SENSE/SYS_DUTGND` 和 `MASTER_OUT/SLAVE_IN` 属于系统校准或 Gang 扩展功能，可按项目需求决定是否使用。

---

## 12. Force Voltage：FIN DAC

关键寄存器：

```text
0x08 FIN DAC x1
0x09 FIN DAC m
0x0A FIN DAC c
0x0B Offset DAC
```

对于 5 V VREF，Force/Comparator DAC 总 span 约 25.625 V。默认 Offset DAC 为 `0x8000` 时，中码附近约对应 0 V：

```text
FIN DAC = 0x8000 -> 约 0 V，相对于 DUTGND
```

默认 m/c 下可近似理解为：

```text
Vout ≈ 25.625 V * (code - 32768) / 65536 + DUTGND
```

实际输出还需考虑 VREF、Offset DAC、Calibration、供电 headroom、DUTGND、外部 Rsense 和线路压降。

---

## 13. Current Clamp

Clamp 用于限制 DUT source/sink 电流。

```text
0x0D~0x0F -> CLL x1/m/c
0x10~0x12 -> CLH x1/m/c
```

实际进入 Clamp 状态时会触发 `CLALM`：

```text
DUT 试图超过设定电流
        |
AD5560 模拟 Clamp 先限流
        |
        +--> CLALM -> FPGA
```

持续故障最终应通过 `SW_INH/HW_INH` 隔离，而不是关闭 Clamp。

---

## 14. Comparator

AD5560 内置电流/电压 Comparator，可不经过 ADC 做窗口判断。

每个 Current Range 有独立 CPL / CPH DAC 组；电压 Comparator 使用 `0x45~0x4A`。

Comparator 适合快速 Pass/Fail；精确数值测量仍走 `MEASOUT + ADC`。

---

## 15. MEASOUT 与外部 ADC

AD5560 实际测量结果主要从模拟 `MEASOUT` 输出，可选择 DUT Current、DUT Voltage、Kelvin Sense、Die Temperature、DUTGND Sense、Diagnostic Nodes。

### 15.1 电流测量链

```text
Current Range
      |
Current Sense / MI Gain
      |
MEASOUT Gain
      |
MEASOUT -> External ADC -> FPGA
```

换算依赖 Current Range、Rsense、MI Gain、MEASOUT Gain 和外部 ADC。

### 15.2 电压测量链

```text
DPS1.ME -> VSENSE
       |
等待建立
       |
ADC sample
       |
FPGA 换算
```

---

## 16. Alarm 系统

主要有三个 Open-Drain、Active-Low 告警引脚：

```text
CLALM  -> Current Clamp Alarm
KELALM -> Kelvin 综合 Alarm
TMPALM -> Temperature Alarm
```

`KELALM` 内部可以由 OSALM、DUTALM、GRDALM 共同产生。

多个 AD5560 的 Alarm 可以 wired-OR，再由 FPGA 扫描各器件 `0x43` 定位。

---

## 17. Alarm Setup Register `0x06`

可以分别配置 TMPALM、OSALM、DUTALM、CLALM、GRDALM 是否映射到外部 pin，以及是否 Latched。

即使某类 Alarm 不输出到硬件 pin，其状态仍可从 `0x43/0x44` 读取。

---

## 18. Alarm Status `0x43 / 0x44`

`0x43` 只读状态，不清 Latched Alarm；`0x44` 读取并清除 Latched Alarm。

Alarm bit 是 Active-Low 语义：

```text
0 = Alarm
1 = No Alarm
```

推荐：

```text
ALARM_N low
 -> 读 0x43 定位并记录
 -> 执行保护
 -> 需要清除时读 0x44
```

---

## 19. Kelvin / Open-Sense 保护

### 19.1 OSD DAC `0x0C`

当 FORCE 与 SENSE 偏差超过 OSD threshold 时，可能触发 `OSALM -> KELALM`。

### 19.2 DGS DAC `0x3D`

用于设置 DUTGND 与 AGND 的异常阈值，对应 `DUTALM/KELALM`。

---

## 20. 温度检测与 Thermal Shutdown

AD5560 内部实际存在三类不同的温度传感机制，不应混在一起理解。

### 20.1 MEASOUT TSENSE

DPS Register 1 的 MEASOUT MUX 可以选择 TSENSE。

典型关系：

```text
25°C -> 约 1.54 V
温度系数 -> 约 4.7 mV/°C
```

该 TSENSE 在 Power-Down 状态仍可工作，适合得到一个普通的 die temperature 模拟量。

### 20.2 Thermal Shutdown 功率级传感器

AD5560 在活动功率级内部还有用于 Thermal Shutdown 的温度传感器。

System Control `TMP[1:0]` 可选择约 100°C、110°C、120°C、130°C（默认）阈值。

超过阈值后芯片会：

```text
Force Amplifier inhibit
SW_INH 自动清 0
TMPALM 拉低
```

Diagnostic Register 还可以把这些功率级相关的 `VPTAT low/high` 和对应参考电压送到 MEASOUT，用于诊断。

### 20.3 GPO Thermal Diode Array

第三类是散布在整个 die 上的片上 Thermal Diode Array，主要用于观察：

- 芯片不同区域的温度；
- 高电流输出级热点；
- DAC / 测量电路附近温度；
- die 上的温度梯度；
- 多颗 AD5560 板级热分布。

这组二极管不是通过 MEASOUT 输出，而是：

```text
Selected Diode D+ -> GPO
Selected Diode D- -> AGND
```

因此需要外部 Remote Diode Temperature Monitor，例如 ADT7461。ADI AD5560 Evaluation Board 也采用 ADT7461 读取这些温度点。

这三套机制的定位可以简单记为：

| 温度机制 | 输出路径 | 主要用途 |
|---|---|---|
| 普通 TSENSE | MEASOUT | 普通 die temperature 监测 |
| Shutdown Sensor / VPTAT | 内部保护；诊断时可到 MEASOUT | 过温保护、功率级诊断 |
| Thermal Diode Array | GPO + AGND | 多点热点/温度梯度测量 |

---

## 21. Compensation

Force Amplifier 有 Safe Mode、Auto Compensation 和 Manual Compensation 三种补偿方式。

Auto Compensation `0x04` 根据 CDUT / ESR 选择内部补偿组合；Manual Compensation `0x05` 可以直接配置 gm、RP、RZ、CF、CC 等参数。

补偿直接影响稳定性、过冲和建立时间。

---

## 22. Slew Rate 与 Ramp Function

### 22.1 Slew Rate

由 `DPS Register 2.SR[2:0]` 控制，是模拟输出路径的变化速度控制。

### 22.2 Ramp Function

Ramp 是 FIN DAC `x1` 本身按步进变化：

```text
0x08 -> 当前 FIN x1 / Ramp Start
0x3E -> Ramp End Code
0x3F -> Ramp Step Size
0x40 -> RCLK Divider
0x41 -> 0xFFFF Enable Ramp
0x42 -> 0x0000 Interrupt Ramp
```

Ramp 期间普通 SPI 命令会被忽略，只接受 Interrupt Ramp，因此启动前要完成其他配置。

详细上下电机理见 [`AD5560_CONTROL.md`](./AD5560_CONTROL.md)。

---

## 23. LOAD 与多器件同步

AD5560 可以把 `CLEN` 或 `HW_INH` 复用为 LOAD。

LOAD 可同步 FIN DAC x2、Clamp DAC x2、Current Range、Compensation 的实际更新。

`LOAD=3` 可以利用共享 BUSY 释放实现多通道同步，而不占用 CLEN/HW_INH 的原功能。

LOAD 不是 Ramp Start。

---

## 24. Diagnostic Register `0x07`

Diagnostic Register 默认值 `0x0000`，主要分为三组字段：

```text
Bit[15:12]  DIAG Select
Bit[11:7]   TSENSE Select
Bit[6:5]    Test Force AMP
Bit[4:0]    Reserved = 0
```

> Rev.F 表格中 TSENSE 字段文字标注存在容易混淆之处，但该字段实际需要表示 `0~31`，对应 Bit[11:7] 的 5-bit 选择值。

### 24.1 DIAG Select[3:0]

用于选择内部 Diagnostic A / B 节点，再配合 DPS Register 1 的 MEASOUT `DIAG A/DIAG B` 选择输出到 MEASOUT。

可访问 Force Amplifier、EXTFORCE、FINP/FINM、Measure Block、VPTAT、DAC、Clamp、Comparator、OSD、DGS 等内部节点。

### 24.2 TSENSE Select[4:0]：GPO 热二极管选择

`TSENSE Select = 0~7`：

```text
不连接片上 Thermal Diode
GPO 保持普通 GPO 功能
```

`TSENSE Select = 8~31`：选择一个具体片上 Thermal Diode，并把其阳极送到 GPO。

主要位置：

| TSENSE Select | 位置 |
|---:|---|
| 8 | 高电流驱动冷端 / 数字区热端附近 |
| 9 | 25 mA Output Stage |
| 10 | 精密测量电路较热区域 / Force Amp 冷端 |
| 11 | Force Amplifier 最冷端 |
| 12 | DAC 最冷端 |
| 13 | MEASOUT TSENSE 附近 |
| 14 | DAC 最热端 |
| 15 | 数字区冷端 |
| 16~23 | Force Amplifier PNP 功率输出级不同位置 |
| 24~31 | Force Amplifier NPN 功率输出级不同位置 |

其中 16~23 和 24~31 对应 EXTFORCE1/2 的多个并联输出级位置，可用于观察 sourcing / sinking 功率级的热分布。

FPGA 配置形式可理解为：

```text
Diagnostic[11:7] = thermal_diode_index
Diagnostic[15:12] = 0       // 若本次不使用 MEASOUT diagnostic
Diagnostic[6:0]   = 0       // 不做 Force Amp stage test
```

选定后二极管连接为：

```text
D+ -> GPO
D- -> AGND
```

外部温度检测器通过测量 PN 结的 ΔVBE 得到温度。

### 24.3 使用 GPO Thermal Diode 时的注意事项

- GPO 此时是模拟 Thermal Diode 端口，不是普通数字输出；
- 外部温度检测器的 D− 应参考 AD5560 的 AGND，布线按敏感模拟信号处理；
- `TSENSE Select` 可以由 FPGA 轮流切换，从而扫描同一颗 AD5560 不同位置；
- 该 Thermal Diode Array 与 `MEASOUT TSENSE`、`TMPALM/Thermal Shutdown` 是三套不同温度机制；
- 恢复普通 GPO 时，将 `TSENSE Select` 设回正常值（通常 0）。

### 24.4 Test Force AMP[1:0]

Bit `[6:5]` 可以单独使能/测试 EXTFORCE1/2 的不同并联输出级，主要用于器件连接性和诊断测试，正常工作保持 0。

---

## 25. FPGA 推荐初始化流程

```text
POWER ON
   |
等待 BUSY = 1
   |
RESET / WAIT BUSY
   |
HW_INH = 0
   |
System Control
DPS Register 2
Compensation
Alarm Setup
OSD / DGS
DPS Register 1
Clamp / Comparator
FIN DAC safe value
Readback verify
   |
SW_INH = 1
   |
按系统时序释放 HW_INH / 启动 Ramp
   |
RUN
```

第一版建议采用：

```text
write -> wait BUSY high -> next dependent transaction
```

---

## 26. FPGA 推荐运行状态机

```text
IDLE / HIGH-Z
    |
    +--> CONFIG
    |
    +--> ENABLE / RAMP
    |
    +--> RUN
    |      +--> MEASOUT / ADC
    |      +--> temperature monitor
    |      +--> status monitor
    |
    +--> FAULT
           +--> scan 0x43
           +--> latch channel/type
           +--> SW_INH/HW_INH disable
           +--> 0x44 clear when allowed
```

---

## 27. 多颗 AD5560 的 FPGA 接口建议

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

如果每颗 AD5560 的 GPO Thermal Diode 都接外部温度检测器，则温度检测器的拓扑还需根据器件数量决定独立、复用或分组方案。

---

## 28. FPGA 推荐模块划分

### 28.1 SPI Physical / Shift Engine

只负责 SCLK、SDI、SDO、SYNC、24-bit Shift。

### 28.2 AD5560 Transaction Controller

负责：

- 目标器件选择；
- Write；
- 两帧 Readback；
- BUSY 等待；
- RESET；
- DAC x1 / 普通寄存器不同时序。

### 28.3 Register / Channel Configuration Layer

维护 System、DPS1/2、Alarm、Compensation、FIN、Clamp、Comparator、Diagnostic 等寄存器 Shadow。

### 28.4 Function Sequencer

实现初始化、Voltage、Range、Clamp、MEASOUT、上下电、Ramp、Alarm 扫描、温度扫描等功能。

---

## 29. 第一阶段建议实现的最小功能集

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
- `0x07` Diagnostic；
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
- Ramp；
- Diagnostic / GPO Thermal Diode Select。

---

## 30. FPGA 实现中特别容易踩坑的点

1. `PD=0` 是 Power-Down；
2. `SW_INH=1` 且 `HW_INH=1` 才允许 Force Amplifier 工作；
3. Alarm Status 是 Active-Low；
4. `0x44` 会清 Latched Alarm；
5. Readback 是两帧；
6. Readback SCLK 低于 write-only SCLK；
7. DAC `x1` 写会进入 Calibration Engine；
8. 写 `m/c` 不会自动刷新当前 DAC 输出；
9. MEASOUT 需要外部 ADC；
10. Current Range 改变后测量、Comparator、Clamp 参数要同步；
11. Compensation 不能忽略；
12. `FORCE` 只用于内部电流档，>25 mA 要看 EXTFORCE1/2；
13. `SYS_FORCE/SYS_SENSE` 是 System PMU 接口，不是普通 DUT 必接线；
14. GPO 选择 Thermal Diode 后不能同时当普通数字 GPO 使用；
15. GPO Thermal Diode 的负端是 AGND，外部 Remote Diode Monitor 的地参考要正确处理。

---

## 31. Datasheet 推荐阅读顺序

如果主要做 FPGA 驱动和寄存器控制，可以按以下顺序阅读 Rev.F：

1. Page 1 ~ 3：Features / Functional Block Diagram；
2. Page 16 ~ 19：Pin Description；
3. Page 29 ~ 35：Force、Measure、Clamp、Current Range、GPO、System Force/Sense、Temperature；
4. Page 36 ~ 39：Compensation；
5. Page 40 ~ 42：DAC Levels、Offset/Gain、Calibration Engine；
6. Page 43 ~ 44：Slew Rate / Ramp；
7. Page 45 ~ 46：Serial Interface、BUSY、LOAD；
8. Page 47 ~ 57：寄存器定义，尤其 DPS Register 2 和 Diagnostic Register；
9. Page 57 ~ 58：Readback / Power-On Default；
10. Page 59 以后：Power Supply、外围、Layout、Thermal。

---

## 32. 后续可继续拆分的文档

后续正式 RTL 开发时可进一步拆分：

1. `AD5560_REGISTER_MAP.md`：完整寄存器 bit / mask / reset / RW；
2. `AD5560_CONVERSION.md`：Voltage、Current、Clamp、Comparator 换算；
3. `AD5560_DRIVER_DESIGN.md`：SPI、BUSY、Readback、Alarm、Shadow；
4. 项目级上下电方案见 [`AD5560_PROJECT_POWER_SEQUENCE.md`](./AD5560_PROJECT_POWER_SEQUENCE.md)。

---

## 33. 官方参考资料

### AD5560 Rev.F Data Sheet

https://www.analog.com/media/en/technical-documentation/data-sheets/AD5560.pdf

### AD5560 Product Page

https://www.analog.com/en/products/ad5560.html

### AD5560 Evaluation Board User Guide

https://wiki.analog.com/resources/eval/ad5560_user_guide

### AN-2507：Integrated Device Power Supply (DPS) for ATE

https://www.analog.com/en/resources/app-notes/an-2507.html

---

## 34. 总结

从 FPGA 角度，AD5560 是一套完整 DPS：

```text
FPGA
 |
 +-- SPI Transaction ------> Register Control
 |
 +-- FIN x1/m/c -----------> Calibration Engine -> x2 -> Force DAC
 |
 +-- Current Range --------> FORCE / EXTFORCE + Measure Path
 |
 +-- SENSE / DUTGND -------> Kelvin Feedback / Protection
 |
 +-- CLL / CLH ------------> Current Clamp
 |
 +-- CPL / CPH ------------> Comparator
 |
 +-- ME MUX ---------------> MEASOUT -> ADC -> FPGA
 |
 +-- Diagnostic -----------> Internal Nodes / Thermal Diode Select
 |
 +-- GPO ------------------> Digital Output OR Thermal Diode D+
 |
 +-- Alarm ----------------> Fault Detect
 |
 +-- Slew / Ramp ----------> Power Sequence
```

其中需要特别区分三类温度信息：普通 `MEASOUT TSENSE`、功率级 Thermal Shutdown Sensor、以及通过 `GPO` 引出的多点 Thermal Diode Array。

对于输出连接，也需要区分：内部电流档使用 `FORCE`，外部高电流档使用 `EXTFORCE1/2`，`SENSE` 和 `DUTGND` 提供 Kelvin 反馈；`SYS_FORCE/SYS_SENSE/SYS_DUTGND` 属于 System PMU 扩展接口，`MASTER_OUT/SLAVE_IN` 属于 Gang 扩展接口。