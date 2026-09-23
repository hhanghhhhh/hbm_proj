# AD5560 FPGA 控制与寄存器使用指南

## 1. 文档目的

本文面向使用 FPGA 控制 AD5560 的开发人员，从“如何通过数字接口控制器件”的角度整理 AD5560 Rev.F 数据手册中的主要内容。

本文主要依据 Analog Devices **AD5560 Rev.F Data Sheet** 整理。模拟外围、电源轨、PCB、散热和外部补偿元件等仍应以原始数据手册为最终依据。

> 本文重点是 AD5560 自身机理和 FPGA 控制接口。已有的 [`AD5560_CONTROL.md`](./AD5560_CONTROL.md) 更侧重 DUT 上下电、`SW_INH/HW_INH`、Slew Rate、Ramp 和 LOAD 时序。

---

## 2. AD5560 是什么

AD5560 是一颗单通道可编程 DPS（Device Power Supply），主要用于 ATE 中给 DUT 供电和测量。

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


## 11. FORCE / EXTFORCE / SENSE / DUTGND 等引脚

这几个引脚功能不同，不能简单理解成“只接 FORCE 和 SENSE 就够了”。

### 11.1 FORCE

`FORCE` 是 **片内五档电流量程**的 Force 输出。



### 11.2 EXTFORCE1 / EXTFORCE2


```text
EXTFORCE1 -> 最大约 ±1.2 A
EXTFORCE2 -> 最大约 ±500 mA
```

高电流档需要配合外部 Sense Resistor 和对应的外部测流引脚。

### 11.3 SENSE

`SENSE` 是 DUT 电压 Kelvin Sense 输入。



### 11.4 DUTGND

`DUTGND` 表示 DUT 实际地电位，是 AD5560 的 DUT Ground Reference / Kelvin Ground 节点，而不是简单等同于板上的 AGND。

对于远端 DUT、Probe Card、较大电流回路，应考虑 DUTGND 走线压降及 DUTGND Kelvin Alarm。

### 11.5 SYS_FORCE / SYS_SENSE

- `SYS_FORCE`：外部 System PMU 的 Force 信号输入；
- `SYS_SENSE`：把本通道 SENSE 节点送给外部 System PMU。

用于系统 PMU 校准和额外测量。普通 DUT 供电不需要它们。

### 11.6 GUARD / SYS_DUTGND

`GUARD/SYS_DUTGND` 为复用引脚：

- Guard 模式：Guard Amplifier 输出，用于高阻/低电流测量时驱动线缆屏蔽层，减小绝缘漏电；
- SYS_DUTGND 模式：把 DUTGND 节点送到 System PMU。

使用 SYS_DUTGND 时必须把 Guard Amplifier 设置为 High-Z。




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


## 33. 官方参考资料

### AD5560 Rev.F Data Sheet

https://www.analog.com/media/en/technical-documentation/data-sheets/AD5560.pdf

### AD5560 Product Page

https://www.analog.com/en/products/ad5560.html

### AD5560 Evaluation Board User Guide

https://wiki.analog.com/resources/eval/ad5560_user_guide

### AN-2507：Integrated Device Power Supply (DPS) for ATE

https://www.analog.com/en/resources/app-notes/an-2507.html


