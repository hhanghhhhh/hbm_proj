# AD5560 软件控制与寄存器使用指南

## 1. 文档目的

本文面向准备使用 AD5560 的 FPGA / MCU / 上位机软件开发人员，重点从“如何控制器件”的角度整理 AD5560 数据手册中的内容，包括：

- AD5560 能完成哪些功能；
- SPI 通信格式、写寄存器和读回流程；
- `RESET`、`BUSY`、`SYNC`、`SDO` 等数字接口的使用方法；
- 主要控制寄存器的作用；
- Force Voltage、Current Range、Measure、Clamp、Comparator 的配置关系；
- `SW_INH` / `HW_INH` 与输出使能；
- Alarm 配置、故障读取与清除；
- Slew Rate 和 Ramp Function；
- Compensation、Calibration、Diagnostic 等进阶功能；
- 推荐的软件初始化顺序和驱动分层方式。

本文主要依据 Analog Devices **AD5560 Rev.F Data Sheet** 整理。具体模拟电路参数、供电轨选择、PCB、散热和外部补偿元件仍应以原始数据手册为最终依据。

> 本文偏软件/寄存器使用。已有的 [`AD5560_CONTROL.md`](./AD5560_CONTROL.md) 更侧重 DUT 上下电、`SW_INH/HW_INH`、Slew Rate 和 Ramp 时序。

---

## 2. AD5560 是什么

AD5560 是一颗单通道可编程 DPS（Device Power Supply），主要用于 ATE 中给 DUT 供电和测量。

从控制软件角度，可以把它理解为以下功能模块的集合：

```text
                 +------------------------+
SPI -----------> | Control Registers      |
                 | DAC / Range / Alarm    |
                 +-----------+------------+
                             |
                             v
VREF ---> 16-bit FIN DAC ---> Force Amplifier ---> FORCE / EXTFORCE ---> DUT
                             ^                         |
                             |                         |
                       SENSE / DUTGND <----------------+
                             |
                             +--> Current Measure
                             +--> Voltage Measure
                             +--> Comparator
                             +--> Clamp
                             +--> Kelvin Alarm
                             +--> MEASOUT ---> 外部 ADC
```

软件最常用的能力包括：

1. **FV（Force Voltage）**：设定 DUT 电压；
2. **MI（Measure Current）**：测 DUT 电流；
3. **MV（Measure Voltage）**：测 DUT 电压；
4. 输出高阻状态下进行电压测量；
5. 多档电流量程；
6. 正负方向 Current Clamp；
7. 电流/电压窗口比较器；
8. Kelvin Sense / DUTGND 连接异常检测；
9. 芯片温度检测和过温关断；
10. 可编程 Slew Rate；
11. DAC Ramp；
12. Offset/Gain 校准；
13. Force Amplifier 补偿；
14. 多颗器件 Gang；
15. Diagnostic 内部节点测量。

AD5560 **没有把电压/电流测量结果转换成数字码的 ADC**。`MEASOUT` 是模拟输出，若系统需要数字化采集，一般需要外部 ADC。

---

## 3. 软件首先要理解的几个概念

### 3.1 Force 与 Measure 是两条逻辑链

Force 路径负责“输出什么电压”：

```text
FIN DAC -> Force Amplifier -> FORCE -> DUT
```

Measure 路径负责“观察 DUT 的电压、电流、温度或内部节点”：

```text
DUT / Sense / Current Sense
        -> Measure MUX
        -> MEASOUT
        -> 外部 ADC
```

因此：

- 写 `FIN DAC` 不等于在读取电压；
- 选择 `MEASOUT` 不改变 Force DAC 的目标电压；
- 软件需要分别管理“输出配置”和“测量配置”。

### 3.2 Current Range 不只是测量量程

`DPS Register 1` 中的 Current Range 会选择实际工作的输出/测流通道。

共有 7 个有效范围：

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

### 3.3 x1 / m / c / x2

AD5560 的很多 DAC 都不是“写一个寄存器就直接送到模拟 DAC”。

内部存在：

- `x1`：用户写入的目标码；
- `m`：Gain 校准系数；
- `c`：Offset 校准系数；
- `x2`：内部校准计算后真正送入 DAC 的码。

关系可表示为：

```text
x1 + m + c
    |
    v
Calibration Engine
    |
    v
x2
    |
    v
Actual DAC
```

数据手册给出的数字校准关系为：

```text
x2 = x1 * (m + 1) / 2^16 + (c - 2^15)
```

默认：

```text
m = 0xFFFF
c = 0x8000
```

此时基本等价于 `x2 = x1`。

软件需要注意：

- `x1/m/c` 可以读回；
- 内部校准后的 `x2` 不能直接通过 SPI 读回；
- 写 `x1` 会启动内部 Calibration Engine，因此会产生较长的 `BUSY`。

---

## 4. SPI 数字接口

## 4.1 相关引脚

与通信直接相关的引脚：

| 引脚 | 方向 | 作用 |
|---|---|---|
| `SYNC` | Input | SPI Frame Sync，低有效，相当于片选 |
| `SCLK` | Input | SPI 时钟，数据手册标明 Active Falling Edge |
| `SDI` | Input | 串行数据输入 |
| `SDO` | Output | 寄存器读回输出 |
| `BUSY` | Open Drain Output | 内部寄存器/DAC 更新忙指示，低有效 |
| `RESET` | Input | 寄存器复位 |

纯写操作的 SCLK 最高可到 **50 MHz**。

读回时由于 `SDO` 驱动较弱，需要降低 SCLK：

| DVCC | Readback 最大建议 SCLK |
|---|---:|
| 2.3 V ~ 2.7 V | 12 MHz |
| 2.7 V ~ 3.3 V | 15 MHz |
| 4.5 V ~ 5.5 V | 20 MHz |

第一版驱动如果不追求速度，建议统一使用较低 SCLK，先保证读写可靠，再优化写操作速率。

---

## 4.2 24-bit 命令格式

每个 SPI 命令固定 **24 bit，MSB First**：

```text
Bit23       Bit22 ........ Bit16   Bit15 ........ Bit0
+----+      +------------------+   +------------------+
|R/W |      | Address[6:0]     |   | Data[15:0]       |
+----+      +------------------+   +------------------+
 1 bit             7 bit               16 bit
```

即：

```text
frame[23]    = R/W
frame[22:16] = register address
frame[15:0]  = register data
```

建议软件统一封装：

```text
frame = (rw << 23) | (addr << 16) | data
```

所有寄存器地址只有 7 bit，范围 `0x00 ~ 0x7F`。

---

## 4.3 写寄存器流程

典型写操作：

```text
SYNC = 1

SYNC = 0
  |
  +-- 发送 24 bit：R/W=0 + Address + Data
  |
SYNC = 1

等待 BUSY / 等待规定时间
```

重要规则：

- `SYNC` 拉低开始一帧；
- 一帧至少 24 个 SCLK；
- `SYNC` 拉高后输入寄存器更新；
- 写操作后 `BUSY` 会拉低一段时间；
- Reserved bit 必须按照数据手册写 0。

软件第一版建议：

> **每完成一次寄存器写入，都等待 `BUSY == 1` 后再执行下一项有依赖关系的配置。**

这样不是最快，但逻辑最简单、安全，后续再根据流水规则优化。

---

## 4.4 `BUSY` 的作用

`BUSY` 是 Open-Drain、低有效输出。

以下操作会让它拉低：

- Power-On Reset；
- 外部 `RESET`；
- 普通寄存器写；
- DAC `x1` 写入及内部 x2 校准计算。

典型软件理解：

```text
BUSY = 0 -> AD5560 内部仍在处理
BUSY = 1 -> 本次内部更新完成
```

数据手册给出的最大量级：

- DAC `x1` write：BUSY Low 最长约 **1.5 µs**；
- 其他普通寄存器写：约 **280 ns**；
- RESET：最长约 **400 µs**。

DAC x1 校准引擎内部是流水结构，第一阶段约 600 ns。因此高性能驱动可以流水发送多次 DAC 更新，但第一版不建议一上来就依赖复杂流水时序。

### 推荐的软件策略

```text
初始化阶段：每次关键写 -> wait_busy_high()

运行阶段：
  普通配置 -> wait_busy_high()
  高频 DAC 更新 -> 后续根据时序优化流水
```

如果多颗 AD5560 的 `BUSY` 被硬件 wired-OR，共享 BUSY 只能表示“这一组是否还有器件忙”，不能直接定位是哪一颗。

---

## 4.5 RESET

`RESET` 拉低会把内部寄存器恢复为 Power-On Default。

推荐流程：

```text
RESET = 0
等待满足最小脉宽
RESET = 1
等待 BUSY = 1
再开始 SPI 初始化
```

Reset 期间不要访问 SPI。

Power-On 时器件自身也会执行内部初始化，此时同样应等待 `BUSY` 上升后再开始通信。

---

## 4.6 读寄存器不是一次 24-bit 就完成

AD5560 Readback 采用“两阶段”流程。

### 第一步：发 Read Request

```text
R/W     = 1
Address = 要读取的寄存器
Data    = 0x0000
```

这一帧只是告诉 AD5560：

> 把这个寄存器内容准备到内部读回移位寄存器中。

### 第二步：再发一帧 NOP

下一次 SPI 操作期间，前一次选择的寄存器内容才从 `SDO` 移出。

```text
Frame 1:
SYNC low
Read(addr)
SYNC high

SYNC high 至少 250 ns

Frame 2:
SYNC low
NOP
同时从 SDO 接收 24 bit
SYNC high
```

可以把驱动 API 封装成：

```c
uint16_t ad5560_read_reg(uint8_t addr)
{
    spi_transfer24(READ | (addr << 16));
    delay_sync_high_min();
    rx = spi_transfer24(NOP);
    return rx & 0xFFFF;
}
```

注意：

- Readback SCLK 不能使用完整 50 MHz；
- `SYNC` 在两帧之间至少保持 High 250 ns；
- `SDO` 在 `SYNC` 拉高后会回到 High-Z；
- `0x43`、`0x44` 是只读寄存器；
- 其他普通可写寄存器一般都可读回；
- 内部 `x2` DAC register 不可读回。

---

## 5. 寄存器总览

软件开发最先需要掌握的是下面这些寄存器。

| 地址 | 名称 | 主要作用 |
|---:|---|---|
| `0x00` | NOP | 空操作，Readback 第二帧常用 |
| `0x01` | System Control | 温度关断、MEASOUT Gain、PD、LOAD 等 |
| `0x02` | DPS Register 1 | SW_INH、Current Range、Comparator、Measure、Clamp Enable |
| `0x03` | DPS Register 2 | Slew Rate、GPO、Gang、System Force/Sense 等 |
| `0x04` | Compensation Register 1 | Auto Compensation：CDUT、ESR、SAFEMODE |
| `0x05` | Compensation Register 2 | 手动补偿参数 |
| `0x06` | Alarm Setup | Alarm latch / disable 配置 |
| `0x07` | Diagnostic | 内部节点、温度二极管、输出级诊断 |
| `0x08` | FIN DAC x1 | Force Voltage 目标值 |
| `0x09` | FIN DAC m | Force DAC Gain 校准 |
| `0x0A` | FIN DAC c | Force DAC Offset 校准 |
| `0x0B` | Offset DAC | 调整整组 DAC 输出基准/范围 |
| `0x0C` | OSD DAC | FORCE-SENSE 开路检测阈值 |
| `0x0D` | CLL DAC x1 | Low Current Clamp |
| `0x10` | CLH DAC x1 | High Current Clamp |
| `0x13 ~ 0x3C` | CPL/CPH DAC | 各 Current Range 的 Comparator Low/High Threshold |
| `0x3D` | DGS DAC | DUTGND Sense Alarm Threshold |
| `0x3E` | Ramp End Code | Ramp 终点 |
| `0x3F` | Ramp Step Size | Ramp 单步大小 |
| `0x40` | RCLK Divider | Ramp Clock 分频 |
| `0x41` | Enable Ramp | 写 `0xFFFF` 启动 Ramp |
| `0x42` | Interrupt Ramp | 写 `0x0000` 中断 Ramp |
| `0x43` | Alarm Status | 读取告警，不清 latched alarm |
| `0x44` | Alarm Status + Clear | 读取并清除 latched alarm |
| `0x45 ~ 0x4A` | VSENSE CPL/CPH | 电压比较器上下阈值及校准 |

---

## 6. System Control Register `0x01`

Power-On Default：`0x0000`。

主要位：

### 6.1 TMP[1:0]：过温关断点

Bit `[15:14]`：

| TMP | Thermal Shutdown |
|---:|---:|
| 0 | 130°C，默认 |
| 1 | 120°C |
| 2 | 110°C |
| 3 | 100°C |

这是 AD5560 芯片结温保护，不是 DUT 温度。

### 6.2 GAIN[1:0]

Bit `[13:12]`：

| GAIN[1:0] | MEASOUT Gain | MI Gain |
|---:|---:|---:|
| 0 | 1 | 20 |
| 1 | 1 | 10 |
| 2 | 0.2 | 20 |
| 3 | 0.2 | 10 |

如果外部 ADC 输入范围较小，经常会使用 `MEASOUT Gain = 0.2`。

### 6.3 FINGND

Bit 11。

- `0`：Force Amplifier 输入连接 Force DAC；
- `1`：Force Amplifier 正输入切到 GND。

正常可编程电压输出一般保持 `FINGND = 0`。

### 6.4 CPO

Bit 10。

用于选择简化 Window Comparator 输出模式，可以减少返回控制器的 Comparator 引脚数量。

### 6.5 PD

Bit 9。

这个位名称容易误解：

- `PD = 0`：Force Amplifier Block Power-Down，Power-On Default；
- `PD = 1`：Force Amplifier Block Power-Up。

因此正常准备输出前，软件需要确认 Force Amplifier Block 已 Power-Up。

注意：如果只是希望 DUT 进入 High-Z，但仍希望满足低泄漏等工作状态，不一定应该直接用 `PD=0`，通常使用 `SW_INH/HW_INH` 做输出禁止。

### 6.6 LOAD[1:0]

Bit `[8:7]`：

| LOAD | 行为 |
|---:|---|
| 0 | 默认，CLEN/HW_INH 保持原功能 |
| 1 | `CLEN` 引脚改作 LOAD |
| 2 | `HW_INH` 引脚改作 LOAD |
| 3 | 不占用硬件 LOAD pin；等待 BUSY high 后同步更新 |

LOAD 主要用于同步：

- FIN DAC；
- CLL / CLH；
- Compensation；
- Current Range。

LOAD **不是 Ramp Start**。

---

## 7. DPS Register 1 `0x02`

Power-On Default：`0x0000`。

这是最常用的运行控制寄存器之一。

### 7.1 SW_INH：软件输出使能

Bit 15：

```text
SW_INH = 0 -> Force Amplifier Disable
SW_INH = 1 -> Force Amplifier Enable 条件满足之一
```

`SW_INH` 与硬件 `HW_INH` 为 AND 关系：

```text
SW_INH = 1
    AND
HW_INH = 1
      |
      v
Force Amplifier Enable
```

因此：

- 软件可以通过 `SW_INH=0` 单独关闭某颗 AD5560；
- FPGA 也可以通过 `HW_INH=0` 快速禁止输出；
- 写 FIN DAC 和输出 Enable 是两个不同动作。

### 7.2 I[2:0]：Current Range

Bit `[13:11]`：

```text
0 -> ±5 uA
1 -> ±25 uA
2 -> ±250 uA
3 -> ±2.5 mA
4 -> ±25 mA
5 -> External Range 2
6 -> External Range 1
```

软件切换量程时，还需要同步考虑：

- 对应 Comparator Threshold；
- Current Clamp；
- 外部 Rsense；
- Compensation；
- 测量换算系数。

不要只改 I[2:0]，却继续沿用另一个量程的电流换算。

### 7.3 CMP[1:0]：Comparator 模式

Bit `[10:9]`：

| CMP | 功能 |
|---:|---|
| 0/1 | Comparator 输出 High-Z |
| 2 | Compare DUT Current |
| 3 | Compare DUT Voltage |

电流比较器上下阈值分别由当前量程对应的 `CPL/CPH DAC` 决定。

### 7.4 ME[3:0]：MEASOUT 选择

Bit `[8:5]`。

`ME[3]` 是 MEASOUT Enable，`ME[2:0]` 选择具体信号。

可选：

```text
0 -> MEASOUT High-Z
1 -> ISENSE
2 -> VSENSE
3 -> KSENSE
4 -> TSENSE
5 -> DUTGND SENSE
6 -> DIAG A
7 -> DIAG B
```

在软件上应把“是否 Enable”和“选择什么信号”分开理解。

典型测量：

```text
测电流：MEASOUT -> ISENSE -> 外部 ADC
测电压：MEASOUT -> VSENSE -> 外部 ADC
测温度：MEASOUT -> TSENSE -> 外部 ADC
```

多个 AD5560 的 MEASOUT 可以在系统层通过适当设计复用到公共 ADC，但必须保证未选通通道处于 High-Z，并考虑模拟建立时间。

### 7.5 CLEN：Clamp Enable

Bit 4。

- `1`：Enable Clamp；
- `0`：Disable Clamp。

该 bit 与硬件 `CLEN` 引脚为 OR 关系：

```text
Clamp Enable = SW_CLEN OR HW_CLEN
```

短路或过流场景下，Clamp 是第一层快速模拟保护。故障后不要通过关闭 CLEN 来处理过流；真正隔离通道应使用 `SW_INH/HW_INH`。

---

## 8. DPS Register 2 `0x03`

### 8.1 SR[2:0]：Programmable Slew Rate

Bit `[14:12]`：

| SR | Slew Rate |
|---:|---:|
| 0 | 1 V/µs |
| 1 | 0.875 V/µs |
| 2 | 0.75 V/µs |
| 3 | 0.62 V/µs |
| 4 | 0.5 V/µs |
| 5 | 0.43 V/µs |
| 6 | 0.35 V/µs |
| 7 | 0.3125 V/µs |

Slew Rate 是 Force DAC 输出放大器的速度控制，不是 DAC code 逐步变化的 Ramp Function。

### 8.2 GPO

Bit 11 控制 GPO，可用于驱动外部辅助功能，例如切换 DUT 端的某些电容或模拟开关。

### 8.3 Gang Mode

Bit `[10:9]` 与多颗 AD5560 并联/Gang 有关，可配置 Master / Slave / FV / FI 等模式。

第一版单器件驱动建议保持默认，不使用 Gang，后续需要大电流并联时再单独设计。

### 8.4 INT10K

Bit 8 可在 FORCE 与 SENSE 之间接入片内约 10 kΩ 路径。

该功能可用于无 DUT 时维持 FORCE/SENSE 连接，但正常 Kelvin 测量时不要随意打开，否则会影响 Open-Sense Detect 的意义和测量精度。

### 8.5 Guard High-Z

Bit 7 可将 Guard Amplifier 置 High-Z。

如果 `GUARD/SYS_DUTGND` 引脚被用作 System DUTGND，需要正确配置该位。

---

## 9. Force Voltage：FIN DAC

### 9.1 关键寄存器

```text
0x08 FIN DAC x1
0x09 FIN DAC m
0x0A FIN DAC c
0x0B Offset DAC
```

正常运行中，最频繁写的是 `0x08`。

### 9.2 默认情况下的电压概念

对于 5 V VREF，Force/Comparator DAC 总 span 大约 25.625 V。

默认 Offset DAC 为 `0x8000` 时，中码附近对应约 0 V：

```text
FIN DAC = 0x8000 -> 约 0 V，相对于 DUTGND
```

在默认 m/c 校准系数下，可近似把电压换算理解为：

```text
Vout ≈ 25.625 V * (code - 32768) / 65536 + DUTGND
```

实际工程必须同时考虑：

- VREF；
- Offset DAC；
- m/c Calibration；
- AVDD/AVSS 和 HCAVDD/HCAVSS headroom；
- DUTGND；
- 线损和外部 Rsense。

因此建议软件不要在业务代码里到处直接写 DAC code，而是统一封装：

```text
voltage_to_fin_code(voltage)
fin_code_to_voltage(code)
```

并给校准参数留接口。

---

## 10. Current Clamp

Clamp 用于限制 DUT source/sink 电流，是 AD5560 很重要的保护功能。

### 10.1 寄存器

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

Clamp 开关由：

```text
DPS Register 1.CLEN
OR
hardware CLEN
```

控制。

### 10.2 CLALM

如果实际输出进入 Clamp 状态，`CLALM` 会触发。

应理解为：

```text
DUT 试图超过设定电流
      |
      v
AD5560 模拟 Clamp 先限流
      |
      +--> CLALM
             |
             v
           FPGA
             |
      读取 0x43 定位
             |
      SW_INH/HW_INH 下电
```

即：Clamp 可以作为第一层快速保护，但不建议把持续 Clamp 当作长期正常工作模式。

---

## 11. Comparator

AD5560 内置电流/电压 Comparator，可以不用 ADC 直接判断 DUT 是否超出窗口。

软件配置涉及：

1. `DPS Register 1.CMP[1:0]` 选择比较电流还是电压；
2. 设置 Low Threshold；
3. 设置 High Threshold；
4. 读取/使用 `CPOL`、`CPOH`，或者读 `0x43/0x44` 中的 comparator status。

### 11.1 电流 Comparator 阈值寄存器

每个 Current Range 有独立 CPL/CPH DAC 组。

| Range | CPL x1 | CPH x1 |
|---|---:|---:|
| ±5 µA | `0x13` | `0x28` |
| ±25 µA | `0x16` | `0x2B` |
| ±250 µA | `0x19` | `0x2E` |
| ±2.5 mA | `0x1C` | `0x31` |
| ±25 mA | `0x1F` | `0x34` |
| EXT Range 2 | `0x22` | `0x37` |
| EXT Range 1 | `0x25` | `0x3A` |

每个 x1 后面紧跟独立 `m` 和 `c` 校准寄存器。

### 11.2 电压 Comparator

```text
0x45 CPL DAC x1：VSENSE comparator low
0x46 CPL DAC m
0x47 CPL DAC c

0x48 CPH DAC x1：VSENSE comparator high
0x49 CPH DAC m
0x4A CPH DAC c
```

这套比较器适合做硬件快速 Pass/Fail、窗口判断，而高精度数值测量仍建议走 `MEASOUT + ADC`。

---

## 12. MEASOUT 与测量

AD5560 的测量结果主要通过模拟 `MEASOUT` 输出。

可选择的内容包括：

- DUT Current；
- DUT Voltage；
- Kelvin Sense；
- Die Temperature；
- DUTGND Sense；
- Diagnostic Nodes。

### 12.1 软件典型测电流流程

```text
1. 选择 Current Range
2. 配置 GAIN[1:0]
3. DPS1.ME 选择 ISENSE
4. 等待模拟 MEASOUT 建立
5. 触发外部 ADC
6. ADC code -> voltage
7. voltage -> DUT current
```

电流换算依赖：

- Current Range；
- Rsense；
- MI Gain（10 或 20）；
- MEASOUT Gain（1 或 0.2）；
- 系统校准。

因此软件建议维护：

```text
current_range ->
{
    rsense,
    mi_gain,
    measout_gain,
    adc_scale,
    calibration
}
```

而不是用一个固定公式处理所有量程。

### 12.2 软件典型测电压流程

```text
1. DPS1.ME 选择 VSENSE
2. 等待 MEASOUT 建立
3. ADC 采样
4. 根据 MEASOUT Gain 和系统校准换算电压
```

---

## 13. Alarm 系统

硬件主要有三个 Open-Drain、Active-Low Alarm 引脚：

```text
CLALM  -> Current Clamp Alarm
KELALM -> Kelvin 相关综合 Alarm
TMPALM -> Temperature Alarm
```

其中 `KELALM` 内部可以由多种原因产生：

- `OSALM`：Open-Sense / FORCE-SENSE 异常；
- `DUTALM`：DUTGND Kelvin 异常；
- `GRDALM`：Guard Alarm。

---

## 14. Alarm Setup Register `0x06`

可以分别控制每一类 Alarm：

- 是否输出到硬件 Alarm pin；
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

即使某一类 Alarm 被禁止输出到硬件 pin，Alarm 状态仍然可以从 `0x43/0x44` 读取。

对于多通道系统，建议关键 Alarm 使用 Latched 模式，避免很短的异常脉冲在 FPGA 扫描之前消失。

---

## 15. Alarm Status `0x43 / 0x44`

这是软件故障处理最重要的两个寄存器。

### 15.1 `0x43`：只读状态，不清除 Latched Alarm

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

**非常容易写错的一点：Alarm bit 是 Active-Low 语义。**

例如：

```text
LCLALM = 0 -> 曾经发生过 Clamp Alarm
CLALM  = 0 -> 当前 Clamp Alarm 仍存在
```

不是 `1 = fault`。

### 15.2 `0x44`：读取并清除 Latched Alarm

`0x44` 的位含义基本与 `0x43` 相同，但是：

> 读取 `0x44` 会自动清除 Latched Alarm pin 和 Latched Alarm bit。

推荐软件故障处理：

```text
Alarm pin low
    |
    v
逐颗 AD5560 读取 0x43
    |
    v
记录 channel + fault type
    |
    v
执行 SW_INH/HW_INH 等保护动作
    |
    v
读取 0x44 清 Latched Alarm
```

不要一收到告警就首先读 `0x44`，否则诊断和清除动作混在一起，不利于软件状态机管理。

---

## 16. Kelvin / Open-Sense 保护

### 16.1 OSD DAC `0x0C`

OSD（Open-Sense Detect）用于设置 FORCE 与 SENSE 之间允许的电压差。

当：

```text
|FORCE - SENSE| > OSD threshold
```

可能触发 Open-Sense Alarm，并通过 `KELALM` 报出。

这对 Wafer Test / Probe 接触检测很重要，因为 Sense 开路时，Force Voltage 闭环信息已经不可靠。

### 16.2 DGS DAC `0x3D`

用于设置 DUTGND 与 AGND 之间的异常阈值。

对应故障通过 DUTALM / KELALM 反馈。

---

## 17. 温度检测与 Thermal Shutdown

AD5560 内部有：

- 用于 Thermal Shutdown 的温度检测；
- 可通过 `MEASOUT` 读取的 TSENSE；
- Diagnostic Register 中可选择的多组片上热二极管。

普通软件至少需要处理：

```text
TMPALM -> 记录器件过温
        -> 对应通道保持禁用
        -> 不要自动立即重启
```

Thermal Shutdown 触发时，AD5560 会自动禁止 Force Amplifier，因此它是最后一级芯片自保护，而不是正常的工作调节机制。

---

## 18. Compensation

AD5560 Force Amplifier 为了适应不同 DUT 电容和 ESR，需要配置补偿。

有三类思路：

1. **Safe Mode**；
2. **Auto Compensation**；
3. **Manual Compensation**。

### 18.1 Safe Mode

Power-On 默认是 Safe Mode。

优点：

- 对未知负载更稳；

缺点：

- 响应很慢。

因此 Safe Mode 很适合器件刚上电、调试阶段，但不一定适合最终高速测试。

### 18.2 Auto Compensation：`0x04`

软件告诉 AD5560：

```text
CDUT 大约是多少
ESR 大约是多少
```

器件自动选择内部补偿组合。

`CDUT[3:0]` 覆盖约 0 nF 到 160 µF；`ESR[3:0]` 覆盖从 mΩ 到 Ω 级范围。

数据手册特别提醒：

- **不要高估 CDUT**，可能导致振荡；
- **不要低估 ESR**，可能导致振荡；
- 反方向估计通常只是响应变慢，而更偏向稳定。

对于第一版软件，如果 DUT 电容和 ESR 可预估，建议优先使用 Auto Compensation，而不是直接手调 Compensation Register 2。

### 18.3 Manual Compensation：`0x05`

可以手工配置：

- gm；
- RP；
- RZ；
- CF；
- CC 等内部补偿网络。

这部分属于调环路阶段，软件应保留配置能力，但不建议业务逻辑频繁修改。

---

## 19. Slew Rate 与 Ramp Function

两者必须严格区分。

### 19.1 Slew Rate

由 `DPS Register 2.SR[2:0]` 控制。

特点：

- Force DAC 的目标码可以直接变化；
- 模拟输出放大器以设定的速度追目标；
- 适合 µs 级较快的输出边沿控制。

### 19.2 Ramp Function

Ramp 是 FIN DAC Code 本身一步一步改变。

寄存器：

```text
0x08 -> Ramp Start：实际就是当前 FIN DAC x1
0x3E -> Ramp End Code
0x3F -> Ramp Step Size
0x40 -> RCLK Divider
0x41 -> 写 0xFFFF 启动 Ramp
0x42 -> 写 0x0000 中断 Ramp
```

Step Size 以 16 LSB 为基本单位。

在 5 V VREF 下：

```text
16 LSB ≈ 6.1 mV
```

RCLK Divider 范围：

```text
/1 ... /255
```

Divider=1 时，RCLK 最大推荐约 833 kHz。

数据手册给出的典型 Ramp Rate 范围，在 5 V VREF、833 kHz RCLK 下可从大约：

```text
24 uV/us ~ 0.775 V/us
```

通过更低 RCLK 还能得到更慢的 Ramp。

### 19.3 Ramp 期间的软件限制

Ramp 运行期间普通 SPI 操作受到限制，应在 Ramp Start 前完成：

- Current Range；
- Clamp；
- Compensation；
- Alarm；
- FIN Start；
- Ramp End；
- Step；
- Divider。

随后再启动 Ramp。

更详细的 DUT 上电顺序见 [`AD5560_CONTROL.md`](./AD5560_CONTROL.md)。

---

## 20. LOAD 与多器件同步

AD5560 没有专门的 LOAD pin，可以把：

- `CLEN`；或
- `HW_INH`

配置为 LOAD。

LOAD 可以让多颗器件先分别写入目标参数，再由一个公共硬件动作统一更新。

适合同步：

- FIN DAC；
- Clamp DAC；
- Current Range；
- Compensation。

如果系统还需要硬件快速 `HW_INH`，一般优先考虑保留 `HW_INH` 原功能，而把 `CLEN` 复用成 LOAD，Clamp Enable 改由寄存器控制。

另外 System Control `LOAD=3` 可以不占用 LOAD pin，而通过共享 BUSY 的释放实现多通道同步更新。

---

## 21. Diagnostic Register `0x07`

Diagnostic Register 可以把很多内部节点送到 `MEASOUT`，用于调试、产测和故障诊断。

包括：

- Force Amplifier 内部节点；
- EXTFORCE 输出级；
- FINP / FINM；
- Measure Block；
- DAC 内部节点；
- Clamp / Comparator DAC；
- OSD / DGS DAC；
- 不同区域的片上温度二极管；
- 高电流输出级分段测试。

正常业务运行可以很少碰 `0x07`，但驱动层建议保留通用接口：

```text
ad5560_set_diag(...)
ad5560_measure_diag(...)
```

方便后续板卡自检和生产测试。

---

## 22. 推荐初始化流程

下面给出一套适合第一版 FPGA/MCU 驱动的软件思路。

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
  - System Force/Sense
  - Gang = default
   |
   v
Compensation
  - Safe / Auto / Manual
   |
   v
Alarm Setup
  - Latched / Enable
   |
   v
OSD / DGS threshold
   |
   v
DPS Register 1
  - Current Range
  - Clamp Enable
  - Measure mode
  - SW_INH 仍保持 0
   |
   v
CLL / CLH
Comparator threshold
   |
   v
FIN DAC = 安全起始值
   |
   v
读回关键寄存器确认
   |
   v
SW_INH = 1
   |
   v
按系统策略释放 HW_INH
或启动 Ramp
   |
   v
RUN
```

第一版建议所有寄存器配置都走：

```text
write -> wait BUSY -> optional readback verify
```

调通以后再优化速度。

---

## 23. 推荐运行时状态机

```text
IDLE / HIGH-Z
    |
    +--> CONFIG
    |      |
    |      +--> voltage
    |      +--> current range
    |      +--> clamp
    |      +--> compensation
    |      +--> alarm
    |
    +--> ENABLE
    |      |
    |      +--> SW_INH/HW_INH
    |      +--> optional Ramp
    |
    +--> RUN
    |      |
    |      +--> measure voltage
    |      +--> measure current
    |      +--> read status
    |
    +--> FAULT
           |
           +--> read 0x43
           +--> record channel/type
           +--> SW_INH=0 or HW_INH=0
           +--> read 0x44 when ready to clear
```

---

## 24. 推荐故障处理逻辑

### 24.1 CLALM

```text
CLALM
 -> 内部 Current Clamp 已先限制电流
 -> FPGA 定位具体器件
 -> 读 0x43
 -> 若持续异常，SW_INH/HW_INH 关闭输出
```

### 24.2 OSALM / DUTALM

代表 Kelvin / Sense 回路不可靠。

对测试系统而言通常不应继续认为当前供电值可信，因此持续异常建议关闭对应通道并标记 Probe / DUT Connection Fault。

### 24.3 TMPALM

芯片已经发生过温保护，应保持通道禁用并等待人工/系统确认散热和功耗原因，不建议温度稍降就自动无条件重启。

---

## 25. 多颗 AD5560 时的软件/接口建议

器件自身 SPI 命令没有“芯片地址”，所以多颗器件必须通过外部 `SYNC` 选择目标器件，或者使用 Daisy Chain。

对于 FPGA 控制的多通道系统，推荐优先考虑：

```text
SCLK  -> Shared
SDI   -> Shared
SYNC  -> 每颗逻辑独立，可由 FPGA + Decoder 产生
SDO   -> 可共享/分组共享
BUSY  -> 可分组 wired-OR
ALARM -> 可分组 wired-OR
RCLK  -> Shared
```

软件层统一使用：

```text
ad5560_write(channel, addr, data)
ad5560_read(channel, addr)
```

而不要让上层业务知道具体 Decoder 片选细节。

---

## 26. 驱动软件建议分层

建议至少分成三层。

### 26.1 SPI Transport Layer

只负责：

```text
select_device(channel)
spi_txrx_24bit()
wait_busy()
reset_device/group()
```

### 26.2 AD5560 Register Driver

负责寄存器位定义和读写：

```text
ad5560_write_reg()
ad5560_read_reg()
ad5560_update_bits()
```

建议维护 Shadow Register，避免修改一个 bit 时破坏同寄存器其他配置。

例如：

```text
shadow.dps1
shadow.dps2
shadow.system
shadow.alarm
```

### 26.3 Functional API

上层不要直接大量操作裸寄存器地址，建议提供：

```text
ad5560_init()
ad5560_set_voltage()
ad5560_set_current_range()
ad5560_set_current_clamp()
ad5560_set_measure_mode()
ad5560_measure_current()
ad5560_measure_voltage()
ad5560_enable_output()
ad5560_disable_output()
ad5560_set_slew_rate()
ad5560_start_ramp()
ad5560_stop_ramp()
ad5560_get_alarm()
ad5560_clear_alarm()
```

这样以后做上位机协议时，上位机只需要使用物理量：

```text
Voltage = 1.10 V
Current Clamp = 300 mA
Ramp = 5 mV/us
```

底层驱动负责换算成 AD5560 寄存器值。

---

## 27. 软件实现中特别容易踩坑的点

### 27.1 `PD=0` 是 Power-Down

不要把 `PD` 当成普通 Enable 位按名字直觉使用。

### 27.2 `SW_INH=1` 才是允许输出

它与 `HW_INH` 是 AND 关系。

### 27.3 Alarm Status 是 Active-Low

`0x43/0x44` 中：

```text
0 = Alarm
1 = No Alarm
```

这一点非常反直觉，建议驱动层立刻转换成统一的：

```text
fault.xxx = true / false
```

不要让 Active-Low 语义泄露到业务层。

### 27.4 `0x44` 会清 Latched Alarm

诊断先读 `0x43`，确认并记录后再读 `0x44`。

### 27.5 Readback 是两帧

第一帧 Read Request，第二帧 NOP 才真正从 SDO 收到数据。

### 27.6 Readback SCLK 比 Write SCLK 慢

不要把纯写的 50 MHz SPI 参数直接用于读回。

### 27.7 DAC x1 写会进 Calibration Engine

`BUSY` 时间比普通控制寄存器更长。

### 27.8 Measure 需要外部 ADC

AD5560 的 `MEASOUT` 是模拟量，不要设计成“读一个 AD5560 寄存器得到实际 DUT 电流”。

### 27.9 Current Range 改变后要同步改变换算和阈值

比较器、电流测量和保护配置都与当前量程有关。

### 27.10 Compensation 不能忽略

高电流 + 大 DUT 电容时，补偿设置直接关系到稳定性、过冲和建立时间。

---

## 28. 建议第一阶段先实现的最小功能集

为了尽快把器件跑起来，第一版 FPGA/软件可以只实现以下功能：

### 底层通信

- 单颗 `SYNC` 选择；
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

### 功能 API

- 初始化；
- 设置电压；
- 设置电流量程；
- 设置 Clamp；
- 开/关输出；
- 测电流；
- 测电压；
- 读 Alarm；
- Ramp。

Comparator、Gang、Diagnostic、Manual Compensation 和完整 Calibration 可以第二阶段加入。

---

## 29. 阅读数据手册的推荐顺序

如果准备正式写驱动，不建议从第 1 页一直顺序读到最后，可以按下面顺序看：

1. **Page 1 ~ 3**：Features + Functional Block Diagram；
2. **Page 16 ~ 19**：Pin Description；
3. **Page 29 ~ 35**：Force、Measure、Clamp、Current Range、Temperature；
4. **Page 36 ~ 39**：Compensation；
5. **Page 40 ~ 42**：DAC、Offset/Gain、Calibration；
6. **Page 43 ~ 44**：Slew Rate / Ramp；
7. **Page 45 ~ 46**：Serial Interface / BUSY / LOAD；
8. **Page 47 ~ 57**：寄存器定义；
9. **Page 57 ~ 58**：Readback / Power-On Default；
10. **Page 59 以后**：供电、外围、Layout、Thermal。

对于软件开发来说，第 45 ~ 58 页是最核心的部分。

---

## 30. 后续建议继续拆分的专题

在本指南读完、器件方案确认以后，建议进一步形成以下独立文档或代码约束：

1. `AD5560_REGISTER_MAP.md`
   - 完整寄存器位定义；
   - mask / shift；
   - reset value；
   - RW 属性。

2. `AD5560_CONVERSION.md`
   - Voltage ↔ FIN code；
   - Current ↔ MEASOUT；
   - Clamp ↔ DAC code；
   - Comparator ↔ code；
   - Calibration 参数。

3. `AD5560_DRIVER_DESIGN.md`
   - FPGA SPI 状态机；
   - 多通道 SYNC；
   - BUSY 调度；
   - Alarm 扫描；
   - API / 寄存器 Shadow。

4. `AD5560_POWER_SEQUENCE.md`
   - DUT 上电；
   - Ramp；
   - 下电；
   - Fault 关断。

现有 `AD5560_CONTROL.md` 已覆盖第 4 项的一部分。

---

## 31. 官方参考资料

### AD5560 Rev.F Data Sheet

https://www.analog.com/media/en/technical-documentation/data-sheets/AD5560.pdf

本文的寄存器地址、位定义、SPI 时序及主要功能均以该版本为主要依据。

### AD5560 Product Page

https://www.analog.com/en/products/ad5560.html

### AD5560 Evaluation Board User Guide

https://wiki.analog.com/resources/eval/ad5560_user_guide

Evaluation Board 软件可用于辅助理解官方推荐的初始化和寄存器操作方式。

### AN-2507：Integrated Device Power Supply (DPS) for ATE

https://www.analog.com/en/resources/app-notes/an-2507.html

更偏完整 DPS 系统、电源轨、外围器件和高电流应用。

---

## 32. 当前结论

从软件视角，AD5560 的核心并不是“写一个 DAC 输出电压”，而是一套完整的 DPS 控制体系：

```text
SPI
 |
 +-- System / DPS Control
 |
 +-- FIN DAC ------------> Force Voltage
 |
 +-- Current Range ------> 输出/测流范围
 |
 +-- CLL / CLH ----------> Current Clamp
 |
 +-- CPL / CPH ----------> Comparator
 |
 +-- ME MUX -------------> MEASOUT -> ADC
 |
 +-- OSD / DGS ----------> Kelvin Protection
 |
 +-- Compensation -------> Force Loop Stability
 |
 +-- Alarm --------------> Fault Detect
 |
 +-- Slew / Ramp --------> Power Sequence
 |
 +-- m/c Calibration ----> Accuracy Correction
```

实际驱动开发时，建议先把 SPI、BUSY、寄存器读回、SW_INH、FIN DAC 和 Alarm 跑通，再逐步加入 Measure、Clamp、Compensation、Ramp 和 Calibration。这样调试路径最清晰。