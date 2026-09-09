# AD5560 控制与上电时序说明

## 1. 文档目的

本文整理 AD5560 在 DUT 供电场景下与输出控制、上下电、电压变化和多器件同步相关的器件机理。

重点包括：

- `FIN DAC`、`SW_INH`、`HW_INH` 与 Force Amplifier 的关系；
- `High-Z`、主动输出 `0 V`、正常输出之间的区别；
- Programmable Slew Rate 与 Ramp Function；
- Ramp Function 的启动、结束和中断机制；
- `LOAD` 的实际作用，以及它与 DAC `x1/x2`、`BUSY`、Ramp 的关系；
- 从下电状态启动到目标电压，以及在线从一个电压变化到另一个电压时，可采用的不同控制方式；
- 多颗 AD5560 的同步和多路电源时序控制方式；
- FPGA 控制时需要注意的器件约束。

本文属于 **AD5560 器件控制手册说明**，用于描述芯片本身提供的各种控制机制，不限定具体项目必须采用其中哪一种方案。

项目级设计文档应根据实际 DUT 的电源时序、斜率和故障处理要求，从本文描述的机制中选择最终方案，并只保留项目真正采用的控制流程。

本文只描述 AD5560 自身控制相关内容，不讨论其他电源方案。

---

## 2. AD5560 控制接口概览

AD5560 是单通道可编程 DPS（Device Power Supply），主要通过 SPI 兼容串行接口进行配置。

与 DUT 输出控制直接相关的数字接口主要包括：

- `SYNC`：SPI 帧同步，低有效；
- `SCLK` / `SDI` / `SDO`：串行接口；
- `RESET`：器件复位；
- `BUSY`：开漏、低有效，表示内部寄存器处理、DAC 校准或更新仍在进行；
- `HW_INH/LOAD`：默认作为 Force Amplifier 硬件禁止输入，也可重配置为 `LOAD`；
- `CLEN/LOAD`：默认作为 Clamp Enable，也可重配置为 `LOAD`；
- `RCLK`：Ramp Function 使用的外部 Ramp Clock；
- `CLALM` / `KELALM` / `TMPALM`：相关故障告警输出。

器件复位或上电后，应等待 `BUSY` 返回 High，确认内部初始化完成，再开始正常寄存器配置。

---

## 3. FIN DAC、SW_INH 与 HW_INH

### 3.1 FIN DAC

`FIN DAC x1` 位于地址 `0x08`，决定 Force Voltage 的目标值。

需要明确：

> 写 FIN DAC 是修改目标电压，不等同于打开或关闭 Force Amplifier。

因此可以在 Force Amplifier 被禁止时预先配置：

- FIN DAC；
- Current Range；
- Current Clamp；
- Compensation；
- Alarm；
- Ramp 参数。

### 3.2 SW_INH

`DPS Register 1` 地址 `0x02`：

- Bit15：`SW_INH`；
- `SW_INH = 1`：允许 Force Amplifier 工作；
- `SW_INH = 0`：禁止 Force Amplifier。

上电默认 `SW_INH = 0`。

### 3.3 HW_INH

`HW_INH/LOAD` 默认作为硬件 Force Amplifier 控制输入。

工作在 `HW_INH` 模式时：

- `HW_INH = 0`：禁止 Force Amplifier，输出 High-Z；
- `HW_INH = 1`：允许 Force Amplifier 工作。

### 3.4 SW_INH 与 HW_INH 的组合关系

`SW_INH` 与 `HW_INH` 为 AND 关系：

```text
SW_INH = 1
    AND
HW_INH = 1
    |
    +--> Force Amplifier Enable
```

任意一个为 0，Force Amplifier 都被禁止。

可以把两者理解为：

- `SW_INH`：SPI/寄存器层面的输出允许；
- `HW_INH`：外部 FPGA 的硬件实时 Enable / Inhibit。

但这只是功能分工上的常见理解，并不要求项目必须固定这样使用。

---

## 4. High-Z 与主动输出 0 V

这是理解 AD5560 上下电和 Ramp 时非常重要的区别。

### 4.1 High-Z

当：

```text
SW_INH = 0
或
HW_INH = 0
```

Force Amplifier 被禁止，DUT 端相当于高阻。

此时 AD5560 **不会主动把 DUT 节点拉到 0 V**。

DUT 节点的实际电压可能由以下因素决定：

- DUT 去耦电容残留电荷；
- 泄放电阻；
- DUT leakage；
- 其他电源轨通过内部结构反灌；
- ESD / 保护二极管；
- Probe Card 或外围网络。

因此：

```text
High-Z != 0 V
```

### 4.2 主动输出 0 V

当：

```text
SW_INH = 1
HW_INH = 1
FIN DAC = 0 V 对应 Code
```

Force Amplifier 已经工作，AD5560 会主动把 DUT rail 调节到 0 V 附近。

这是一个低输出阻抗的主动驱动状态。

如果 DUT 节点原本带有电荷，AD5560 可能需要 sink 电流将其拉向 0 V。

因此在多电源轨 DUT 中：

- “未上电 Rail 保持 High-Z”；
- “未上电 Rail 被主动钳在 0 V”；

是两种不同的系统状态，必须由 DUT Power Sequence 需求决定，不能混为一谈。

### 4.3 推荐在状态机中区分状态名称

从控制逻辑角度，建议至少区分：

```text
OFF_HIZ
    = Force Amplifier 禁止，输出 High-Z

ZERO_FORCE
    = Force Amplifier Enable，FIN = 0 V

RAMP_ACTIVE
    = Force Amplifier Enable，FIN 正在按 Ramp 变化

ON
    = Force Amplifier Enable，FIN 已到目标工作电压
```

这样可以避免把“下电”和“0 V 输出”混成同一个概念。

---

## 5. FIN DAC 写入后的实际更新路径

AD5560 的 FIN DAC 不是简单的“SPI 写 0x08 后直接把该 16-bit 原码送到模拟 DAC”。

内部可以理解为：

```text
FPGA SPI
   |
   v
FIN x1 Register (0x08)
   |
   | 读取当前 m / c
   v
Calibration Engine
   |
   v
FIN x2
   |
   v
Actual Resistor-String DAC
   |
   v
Force Amplifier
```

其中：

- `x1`：SPI 可写、可读的目标码；
- `m/c`：Gain / Offset Correction 系数；
- `x2`：Calibration Engine 计算后的实际 DAC 数据；
- `x2` 不支持通过 SPI 直接 Readback。

默认没有启用外部 LOAD 延迟更新时，写入新的 `x1` 后：

```text
Write FIN x1
    |
    v
Calibration Engine 计算 x2
    |
    | BUSY = Low
    v
x2 Ready
    |
    | BUSY -> High
    v
Actual DAC 更新
```

因此“FIN DAC 写入后直接更新”更准确的说法是：

> 在默认直接更新模式下，写 `x1` 会触发 Calibration Engine，计算完成后新的 `x2` 自动更新到实际 DAC；并不是 SPI 帧结束的瞬间模拟输出立即变化。

DAC `x1` 写入涉及 Calibration Engine，`BUSY` Low 时间可达到约 1.5 us 量级。

---

## 6. 两种输出变化速度控制方式

AD5560 有两套不同机制，不能混淆。

### 6.1 Programmable Slew Rate

`DPS Register 2` 地址 `0x03`，`SR[2:0]` 位于 Bit[14:12]。

典型可选 Slew Rate：

| SR | Slew Rate |
|---:|---:|
| 0 | 1 V/us |
| 1 | 0.875 V/us |
| 2 | 0.75 V/us |
| 3 | 0.62 V/us |
| 4 | 0.5 V/us |
| 5 | 0.43 V/us |
| 6 | 0.35 V/us |
| 7 | 0.3125 V/us |

该功能通过改变 Force DAC 输出放大器相关内部补偿，限制模拟输出追踪目标值的速度。

例如：

```text
FIN DAC = 1.1 V
SW_INH = 1
HW_INH = 0
```

随后：

```text
HW_INH: 0 -> 1
```

Force Amplifier 开始向已预设的 1.1 V 目标值变化，输出边沿受 Slew Rate、Current Range、负载电容及环路条件共同影响。

Slew Rate 适合较快的受控电压变化，但不能把 `DeltaV / Slew Rate` 当成高精度 Ramp 定时器。

### 6.2 Ramp Function

Ramp Function 的本质不同：

> Ramp 过程中 FIN DAC `x1` code 本身按步进逐渐增加或减小。

相关寄存器：

| 地址 | 功能 |
|---|---|
| `0x08` | FIN DAC x1；Ramp 开始前的当前值就是 Start Code |
| `0x3E` | Ramp End Code |
| `0x3F` | Ramp Step Size |
| `0x40` | RCLK Divider |
| `0x41` | Enable Ramp，写 `0xFFFF` 启动 |
| `0x42` | Interrupt Ramp，写 `0x0000` 中断 |

Ramp Step Size 以 16 LSB 为基本步进单位，更新节拍由外部 `RCLK` 与 Divider 决定。

Divider = 1 时，数据手册给出的 RCLK 最大约 833 kHz。

Ramp 启动后通常需要约：

```text
(2 x Divider + 2) 个 RCLK
```

才开始实际更新，并可能存在约 +/-1 个 RCLK 的启动不确定性。

Ramp 的每一步都会更新 FIN `x1`，并经过 Calibration Engine 生成新的 `x2` 后作用到实际 DAC。

---

## 7. 两类典型电压控制场景

AD5560 的控制可以先按两类场景理解。

### 7.1 场景 A：High-Z / 下电状态 -> 工作电压

这是“真正的上电”。

可以有多种实现方式。

#### 方法 A：预设目标 FIN + HW_INH/SW_INH + Slew Rate

```text
High-Z
  |
  | FIN 已预设为 V_TARGET
  v
Enable Force Amplifier
  |
  v
输出按模拟 Slew Rate 追到 V_TARGET
```

适合 Slew Rate 范围本身能够满足 DUT 要求的情况。

#### 方法 B：先进入主动起始电压，再用 Ramp Function

典型为：

```text
High-Z
  |
  v
Force Amplifier Enable
FIN = 0 V
  |
  v
ZERO_FORCE
  |
  v
Ramp Start
  |
  v
0 V -> V_TARGET
```

适合需要远慢于 Programmable Slew Rate、并要求斜率由数字 Step/RCLK 明确控制的情况。

需要注意：

> `High-Z -> 主动 0 V` 这一段本身不属于 Ramp Function。

如果 High-Z 状态下 DUT 节点并不在 0 V，那么 Force Amplifier Enable 后，DUT 会先从当前电压进入主动 0 V 状态，再开始 Ramp。

### 7.2 场景 B：已经在线输出 V1 -> V2

Force Amplifier 已经 Enable，此时不涉及 High-Z 切换。

也可有两种方法。

#### 方法 A：直接写新的 FIN DAC + Slew Rate

```text
V1
 |
 | Write FIN = V2
 v
Force Amplifier 按设定 Slew Rate 追踪
 |
 v
V2
```

适合普通在线电压调整。

#### 方法 B：Ramp Function

```text
FIN x1 = V1
Ramp End = V2
Step / Divider / RCLK 配置完成
  |
  v
Ramp Enable
  |
  v
V1 -> ... -> V2
```

这通常是 Ramp Function 最直接的使用方式，因为 Force Amplifier 已经处于工作状态。

---

## 8. Ramp Function 用于 DUT 上电时的典型顺序

假设目标是从 0 V Ramp 到 `V_TARGET`。

### 8.1 初始安全状态

```text
HW_INH = 0
SW_INH = 0
```

Force Amplifier 禁止，DUT 为 High-Z。

### 8.2 Ramp 前完成静态配置

包括：

- Current Range；
- Clamp / Current Limit；
- Compensation；
- Alarm；
- Ramp Step Size；
- RCLK Divider；
- 其他本次工作模式需要的参数。

### 8.3 设置起点和终点

```text
FIN DAC x1 = 0 V
Ramp End Code = V_TARGET
```

Ramp Start 没有独立寄存器，启动 Ramp 时当前 FIN `x1` 就是 Start Code。

### 8.4 先进入 ZERO_FORCE

例如：

```text
SW_INH = 1
HW_INH = 0
```

DUT 仍为 High-Z。

随后：

```text
HW_INH = 1
```

此时：

```text
SW_INH = 1
HW_INH = 1
FIN DAC = 0 V
```

Force Amplifier 已经接管 DUT，DUT 被主动调节到 Ramp 起始电压。

### 8.5 启动 Ramp

写：

```text
Address = 0x41
Data    = 0xFFFF
```

之后 AD5560 内部 Ramp Engine 根据：

```text
FIN x1 Start Code
Ramp End Code
Ramp Step Size
RCLK
RCLK Divider
```

逐步更新 FIN x1，直到目标值。

完整过程：

```text
OFF_HIZ
  |
  v
配置静态参数
  |
  v
FIN = 0 V
Ramp End = V_TARGET
  |
  v
ZERO_FORCE
  |
  v
Ramp Enable
  |
  v
RAMP_ACTIVE
0 V -> ... -> V_TARGET
  |
  v
ON
```

### 8.6 不应先 Ramp 完再打开 Force Amplifier

如果：

```text
HW_INH = 0
FIN: 0 -> V_TARGET 完成 Ramp
然后 HW_INH = 1
```

则 DUT 在 Ramp 期间一直 High-Z，最后仍然是从 High-Z 直接接到目标电压，Ramp 没有作用到 DUT。

---

## 9. Ramp 结束、中断与状态判断

### 9.1 Ramp 的结束条件

Ramp 会在以下情况之一发生时退出：

1. FIN x1 到达 Ramp End Code；
2. 控制器写 `0x42 = 0x0000` 执行 Interrupt Ramp；
3. 已使能的 Alarm 触发，使 Ramp 被中断。

被中断时，FIN DAC 停留在当时已经到达的值，并退出 Ramp Mode。

### 9.2 没有专用 RAMP_DONE 标志

AD5560 没有独立的：

```text
RAMP_DONE pin
```

也没有专门的 Ramp Complete status bit 供 FPGA 轮询。

`0x41` 是 Ramp 启动命令地址，不应把它理解成会保持 `0xFFFF` 的运行状态寄存器。

### 9.3 FPGA 如何确认 Ramp 完成

FPGA 已知：

- Start Code；
- End Code；
- Step Size；
- Divider；
- RCLK 频率。

因此可以在 FPGA 中根据参数计算 Ramp 所需步数和预计时间，并加入必要 margin。

概念上的步数为：

```text
N ~= ceil(abs(END - START) / STEP)
```

还需要计入 Ramp 启动内部延迟以及 RCLK 相位不确定性。

如果需要进一步确认，可在预计完成后读取：

```text
FIN DAC x1 (0x08)
```

检查是否已经达到 Ramp End Code。

同时 FPGA 应监视 Alarm；如果 Ramp 期间 Alarm 先发生，应按 Ramp Abort 处理，而不能仅依赖预计结束时间。

---

## 10. Ramp 与硬件触发

Ramp Function 不能由：

- `HW_INH`；
- `CLEN/LOAD`；
- `HW_INH/LOAD`；
- 其他外部硬件引脚；

直接触发。

Ramp 的启动方式是 SPI 命令：

```text
Write 0x41 = 0xFFFF
```

因此必须区分：

```text
HW_INH
    -> 控制 Force Amplifier 是否工作/是否 High-Z

LOAD
    -> 控制部分已经准备好的内部更新什么时候真正作用到输出

Ramp Enable
    -> 控制 FIN x1 是否开始按照 Ramp Engine 逐步变化
```

三者是不同功能。

---

## 11. LOAD 的实际作用

### 11.1 LOAD 不是 Power Enable，也不是 Ramp Start

`LOAD` 最主要的用途是：

> 允许控制器先把新的 DAC / Range / Compensation 数据准备好，但暂时不让这些新值作用到实际输出；等 LOAD 条件到来时再统一更新。

它适合解决“多颗器件或多个内部参数需要同步生效”的问题。

它不负责：

- Force Amplifier Enable；
- High-Z / 输出连接控制；
- Ramp Function 启动。

### 11.2 LOAD 与 x1/x2 的关系

以 FIN DAC 为例，可以把内部数据路径理解为：

```text
SPI Write
   |
   v
FIN x1 Register
   |
   v
Calibration Engine
   |
   v
new FIN x2 ready
   |
   |  是否立即更新由 LOAD 模式决定
   v
Actual DAC
```

因此：

> LOAD 不是把某个额外“预写寄存器”复制到 FIN x1；FIN x1 在 SPI 写入时已经更新。LOAD 控制的是经过 Calibration Engine 得到的新 `x2` 以及相关受 LOAD 控制的数据，什么时候真正加载到实际工作部分。

### 11.3 System Control 的 LOAD 模式

`System Control Register 0x01` 的 `LOAD[1:0]` 用于选择更新方式。

#### `LOAD = 0`

默认直接更新模式。

```text
Write x1
  |
  v
Calibration Engine
  |
  v
x2 Ready / BUSY High
  |
  v
Actual DAC 自动更新
```

不需要外部 LOAD 动作。

#### `LOAD = 1`

`CLEN/LOAD` 引脚被重配置为 LOAD。

控制器可以先写好新值，之后通过外部 LOAD 动作统一更新。

该模式下 `CLEN/LOAD` 不再承担原来的硬件 CLEN 功能。

#### `LOAD = 2`

`HW_INH/LOAD` 引脚被重配置为 LOAD。

此时该引脚不再承担硬件 `HW_INH` 功能，因此如果系统依赖 HW_INH 做快速关断，应谨慎使用这种模式。

#### `LOAD = 3`

不占用额外 LOAD 引脚，利用 `BUSY` 的释放实现同步更新。

多颗 AD5560 的 `BUSY` 为 open-drain，可按设计要求 wired-OR。只有当共享 BUSY 恢复 High，表示这一组相关内部计算都完成后，才进行同步更新。

该模式适合多器件同步更新，又希望保留 `CLEN` 和 `HW_INH` 原始功能的情况。

### 11.4 LOAD 可以同步哪些内容

LOAD 主要用于同步以下更新：

- FIN DAC；
- CLL / CLH DAC；
- Current Range；
- Compensation。

具体使用时应以数据手册对应寄存器/LOAD 说明为准。

### 11.5 LOAD 的典型使用场景

例如多个通道已经处于在线工作状态：

```text
AD5560 #0: V1 -> 准备 V1_new
AD5560 #1: V2 -> 准备 V2_new
AD5560 #2: V3 -> 准备 V3_new
```

如果直接分别写入并立即生效，各通道之间会存在 SPI 顺序带来的更新 skew。

使用 LOAD 时可以：

```text
分别准备 #0 / #1 / #2 的新值
          |
          v
所有通道等待
          |
          v
统一 LOAD
          |
          v
多通道同步生效
```

因此 LOAD 更适合“同步更新已有工作通道”，而不是承担普通上电时序。

---

## 12. 多颗 AD5560 的控制与同步

### 12.1 HW_INH 同步 Enable

如果多个 AD5560 已经预配置目标 FIN DAC，可以让多个器件共用一根 `HW_INH`：

```text
FPGA GROUP_EN
   |
   +--> AD5560 #0 HW_INH
   +--> AD5560 #1 HW_INH
   +--> AD5560 #2 HW_INH
```

可实现多个 Force Amplifier 的硬件级同时 Enable。

这与 LOAD 的“同步 DAC 数据更新”不是同一件事。

### 12.2 多电源轨顺序 Enable

FPGA 可以分别控制各路/各组 `HW_INH`：

```text
t = 0      Rail0 HW_INH = 1
t = T1     Rail1 HW_INH = 1
t = T2     Rail2 HW_INH = 1
```

适用于：

- High-Z -> 工作状态的硬件时序控制；
- 配合 Programmable Slew Rate；
- 故障时快速硬件禁止输出。

### 12.3 多颗器件的 Ramp 时序

Ramp 没有公共硬件 Start pin。

多个 AD5560 必须分别执行：

```text
Write 0x41 = 0xFFFF
```

因此 Ramp 起始时刻存在：

- SPI 命令顺序产生的 skew；
- Ramp Engine 相对于 RCLK 的启动不确定性。

如果系统只要求 us/ms 级先后顺序，通常可以由 FPGA 定时后顺序发送 Ramp Enable 命令。

如果要求极严格的多通道 Ramp 同步，则必须单独计算 SPI 和 RCLK 带来的时序误差。

### 12.4 多通道在线同步电压变化

如果多个已经在线的通道需要在同一时刻由各自 V1 切换到新的 V2，并且同步精度高于顺序 SPI 写能够提供的水平，则 LOAD 更有价值。

这也是 LOAD 与多路 Ramp Sequence 的主要区别：

```text
LOAD
  -> 多路“准备好的值”同步生效

Ramp Enable
  -> 某一路开始执行内部 Ramp
```

---

## 13. 下电控制

### 13.1 直接禁止输出

直接执行：

```text
HW_INH = 0
或
SW_INH = 0
```

会使 Force Amplifier 进入 High-Z。

此后 DUT rail 的下降过程主要由 DUT 电容、负载、泄放和外围电路决定，并不等于受控 Ramp Down。

### 13.2 受控下降到 0 V 再进入 High-Z

如果需要明确控制下降斜率，可以：

```text
ON
 |
 v
Ramp Down: V_TARGET -> 0 V
 |
 v
ZERO_FORCE
 |
 v
HW_INH / SW_INH = 0
 |
 v
OFF_HIZ
```

这种方式把：

- 电压受控下降；
- 最终物理断开/High-Z；

分成两个独立步骤。

---

## 14. FPGA 控制状态机示例

本文不是项目方案，因此这里只给出器件能力的示例状态划分。

### 14.1 Ramp 上电示例

```text
RESET
  |
  v
WAIT_BUSY_HIGH
  |
  v
OFF_HIZ
  |
  v
CONFIG_STATIC
  Current Range
  Clamp
  Compensation
  Alarm
  Ramp Step
  RCLK Divider
  |
  v
SET_RAMP
  FIN = START
  Ramp End = TARGET
  |
  v
ZERO_FORCE
  SW_INH = 1
  HW_INH = 1
  |
  v
RAMP_ENABLE
  Write 0x41 = 0xFFFF
  |
  v
RAMP_ACTIVE
  |
  +--> Alarm / Abort -> FAULT
  |
  v
ON
```

### 14.2 普通 Slew Rate 上电示例

```text
OFF_HIZ
  |
  v
FIN = TARGET
SR = desired slew
SW_INH = 1
  |
  v
HW_INH = 1
  |
  v
Force Amplifier 按 SR 追踪目标
  |
  v
ON
```

### 14.3 在线电压调整示例

```text
ON at V1
  |
  +--> Write FIN=V2 + Slew Rate --> ON at V2
  |
  +--> Ramp V1 -> V2 -----------> ON at V2
```

项目级文档应从这些能力中只保留最终选用的方法。

---

## 15. 器件控制约束总结

1. 复位完成后先等待 `BUSY = High`，再开始寄存器配置；
2. FIN DAC 与 Force Amplifier Enable 是两个不同概念；
3. `SW_INH = 1` 且 `HW_INH = 1` 时 Force Amplifier 才允许工作；
4. `High-Z` 与主动输出 `0 V` 完全不同；
5. 默认 `LOAD=0` 时，写 FIN x1 后经过 Calibration Engine，新的 x2 在内部处理完成后自动作用到实际 DAC；
6. LOAD 控制的是“已经准备好的内部新值什么时候真正生效”，不是额外的 FIN x1 预写寄存器；
7. LOAD 不负责 Power Enable，也不能启动 Ramp；
8. Programmable Slew Rate 和 Ramp Function 是两种不同的输出变化机制；
9. 使用 Ramp Function 给 DUT 上电时，Ramp 之前 Force Amplifier 必须已经作用于 DUT，通常先进入 Ramp Start 电压；
10. Ramp 只能通过 `0x41 = 0xFFFF` 启动；
11. Ramp 运行期间普通 SPI 操作受限，应在启动前完成相关配置；
12. AD5560 没有专用 `RAMP_DONE` 标志，FPGA 可依据已知参数计时，并在需要时读回 FIN x1 确认是否达到 End Code；
13. Ramp 期间 Alarm 可以导致 Ramp 中断；
14. 直接 `HW_INH/SW_INH` 禁止输出会进入 High-Z，不等于受控 Ramp Down；
15. 如果下电也要求受控斜率，应先 Ramp 到目标低电压（例如 0 V），再进入 High-Z；
16. 多颗器件的 Ramp 启动需要考虑 SPI 顺序 skew 与 RCLK 不确定性；
17. 多颗在线通道需要同步更新 DAC/Range/Compensation 时，LOAD 比单纯顺序 SPI 写更适合；
18. 项目级设计应根据实际 DUT 需求，从上述机制中选择唯一或少量最终控制路径，避免同时维护多套无用流程。

---

## 16. 参考资料

- Analog Devices, **AD5560 Rev.F Data Sheet**: https://www.analog.com/media/en/technical-documentation/data-sheets/AD5560.pdf
