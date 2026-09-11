# AD5560 控制与上电时序说明

## 1. 文档目的

本文整理 AD5560 在 DUT 供电场景下与输出控制、上下电、电压变化和多器件同步相关的器件机理。

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

## 5. FIN DAC 的完整数据链路与计算关系

AD5560 的 FIN DAC 不是简单地把 SPI 写入的 16-bit 原码直接送入模拟 DAC。

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

因此应区分：

```text
Raw DAC span          = 5.125 x VREF
VREF = 5 V 时         = 25.625 V

Nominal FV span       ~= 25 V
Usable overall range  ~= -22 V ... +25 V
```

`5.125` 本身固定，不能通过寄存器关闭或修改；有效数字增益由 `m` register 另外控制。

### 5.3 x1 -> x2：Calibration Engine

DAC 数字校准公式为：

```text
x2 = x1 x (m + 1) / 2^16 + (c - 2^15)
```

即：

```text
x2 = x1 x (m + 1) / 65536 + (c - 32768)
```

其中：

| 参数 | 含义 | 默认值 |
|---|---|---:|
| `x1` | 写入 FIN DAC input register 的 16-bit code | `0x8000` |
| `m` | Gain Correction | `0xFFFF` |
| `c` | Offset Correction | `0x8000` |
| `x2` | Calibration Engine 计算后送入实际 DAC 的 code | 内部值 |

默认：

```text
m = 0xFFFF -> (m + 1) / 65536 = 1
c = 0x8000 -> c - 32768 = 0
```

因此默认情况下：

```text
x2 = x1
```

`m` 和 `c` 是数字校准参数：

- `m` 改变 `x1 -> x2` 的斜率，即有效数字增益；
- `c` 对 `x2` 增加固定偏移；
- 二者都位于实际 resistor-string DAC 之前。

### 5.4 x2 -> Force 电压

Force DAC 的转换关系为：

```text
VFORCE = 5.125 x VREF x x2 / 65536
       - 5.125 x VREF x OFFSET_DAC_CODE / 65536
       + DUTGND
```

整理为：

```text
VFORCE = (5.125 x VREF / 65536) x (x2 - OFFSET_DAC_CODE)
       + DUTGND
```

这里：

- `x2` 是经过 `m/c` Calibration Engine 后的 FIN DAC code；
- `OFFSET_DAC_CODE` 是独立 Offset DAC 的 code，用于平移 Force/Clamp/Comparator 等 DAC 的工作窗口；
- `DUTGND` 是整个 DUT 电压的参考基准。

将 `x2` 公式代入，可以得到从 `x1` 到 Force 电压的完整关系：

```text
VFORCE = (5.125 x VREF / 65536)
         x [x1 x (m + 1) / 65536
            + (c - 32768)
            - OFFSET_DAC_CODE]
         + DUTGND
```

这个公式是理解电压设置、校准和 Ramp 的基础。

### 5.5 c register 与 Offset DAC 的区别

两者名称都带 Offset，但作用位置不同：

```text
c register
    -> Calibration Engine 内部的数字 offset correction
    -> 直接修正 x1 -> x2

Offset DAC
    -> 独立的 16-bit DAC
    -> 用于整体移动约 25 V 的 Force 输出窗口
```

软件和 RTL 中建议始终使用不同名称，例如：

```text
FIN_C_CAL
OFFSET_DAC_CODE
```

避免把两者混淆。

### 5.6 默认直接更新时序

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

> 在默认直接更新模式下，写 `x1` 会触发 Calibration Engine；计算完成后新的 `x2` 自动更新到实际 DAC，并不是 SPI 帧结束瞬间模拟输出立即变化。

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
| 3 | 0.625 V/us |
| 4 | 0.5 V/us |
| 5 | 0.4375 V/us |
| 6 | 0.35 V/us |
| 7 | 0.313 V/us |

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

### 6.2 Ramp Function 的本质

Ramp Function 的本质是：

> **Ramp Engine 直接在 FIN DAC `x1` code 上做加减；每一步得到新的 `x1` 后，再经过 Calibration Engine 计算新的 `x2`，最后更新实际 DAC。**

数据链路为：

```text
FIN x1 Start Code
      |
      | +/- Ramp Step Size
      v
new FIN x1
      |
      v
Calibration Engine (m/c)
      |
      v
new FIN x2
      |
      v
Actual DAC
      |
      v
Force Amplifier / DUT
```

因此 Ramp Step Size **不是直接加在 x2 上，也不是在 Calibration Engine 后对模拟电压直接增加一个固定值**。

相关寄存器：

| 地址 | 功能 |
|---|---|
| `0x08` | FIN DAC x1；Ramp 开始前的当前值就是 Start Code |
| `0x3E` | Ramp End Code，与 FIN x1 属于同一 code 域 |
| `0x3F` | Ramp Step Size，定义 x1 每一步变化多少 |
| `0x40` | RCLK Divider |
| `0x41` | Enable Ramp，写 `0xFFFF` 启动 |
| `0x42` | Interrupt Ramp，写 `0x0000` 中断 |

### 6.3 Ramp Step Size 寄存器

`0x3F` 的 `D6:D0` 定义 Step Size，以 `16 LSB` 为基本单位。

数据手册给出的关系为：

```text
0000000 -> 16 LSB
0000001 -> 16 LSB
0000010 -> 32 LSB
...
1111111 -> 2032 LSB
```

因此可以写成：

```text
STEP_X1 = 16 x max(STEP_REG, 1)
```

其中：

```text
STEP_REG = 0 ... 127
STEP_X1  = 16 ... 2032 x1-LSB
```

例如：

```text
STEP_REG = 1   -> STEP_X1 = 16
STEP_REG = 10  -> STEP_X1 = 160
STEP_REG = 127 -> STEP_X1 = 2032
```

这里的 LSB 首先应理解为 **FIN DAC x1 code 的 LSB**。

### 6.4 Ramp 每一步的 x1 更新

设：

```text
x1[k]     = 当前 FIN x1
END       = Ramp End Code
S         = STEP_X1
```

上升 Ramp：

```text
x1[k+1] = min(x1[k] + S, END)
```

下降 Ramp：

```text
x1[k+1] = max(x1[k] - S, END)
```

Ramp 的方向由当前 FIN `x1` 与 `Ramp End Code` 的大小关系决定。

如果最后剩余的 code 差小于一个完整 Step，最后一步自动缩小，使 FIN x1 恰好到达 End Code。

因此：

> Ramp Start Code、Ramp End Code 和 Ramp Step Size 都在 `x1` code 域中定义。

### 6.5 Ramp Step 经过 Calibration Engine 后的实际 code 变化

因为：

```text
x2 = x1 x (m + 1) / 65536 + (c - 32768)
```

相邻两步做差：

```text
Delta_x2 = Delta_x1 x (m + 1) / 65536
```

对于一个正常的完整 Ramp Step：

```text
Delta_x1 = STEP_X1
```

因此：

```text
Delta_x2 = STEP_X1 x (m + 1) / 65536
```

忽略整数取整带来的小量化误差，可以得到实际单步 Force 电压变化：

```text
Delta_V_STEP
    = (5.125 x VREF / 65536)
      x STEP_X1
      x (m + 1) / 65536
```

即：

```text
Delta_V_STEP
    = 5.125 x VREF x STEP_X1 x (m + 1) / 65536^2
```

由这个差分公式可以直接看出：

- `m` 会影响实际 Ramp 电压步长；
- `VREF` 会影响实际 Ramp 电压步长；
- `c` 是固定 offset，做差后消失，因此不影响 Ramp 步长；
- `Offset DAC` 只平移整个输出窗口，做差后消失，因此不影响 Ramp 步长；
- `DUTGND` 是公共基准，做差后也不影响 Ramp 步长。

### 6.6 为什么数据手册写 16 LSB = 6.1 mV

当 `VREF = 5 V` 时，AD5560 的 raw DAC span 为：

```text
5.125 x 5 V = 25.625 V
```

但数据手册 Ramp 表使用的是约 `25 V nominal Force span` 的口径，因此：

```text
1 LSB ~= 25 V / 65536
      ~= 381.47 uV
```

于是：

```text
16 LSB ~= 6.1035 mV
2032 LSB ~= 775.15 mV
```

这就是 Ramp Step Size 表中：

```text
16 LSB   ~= 6.1 mV
2032 LSB ~= 775 mV
```

的来源。

需要注意：如果直接使用 `25.625 V raw span` 且 `m = 0xFFFF`，则理论 raw code 换算会得到：

```text
1 raw DAC LSB ~= 25.625 V / 65536 ~= 391.0 uV
16 LSB        ~= 6.256 mV
```

两种结果的区别来自：

```text
25.625 V = 包含 overrange 的 raw DAC span
25 V     = datasheet 对正常 Force Voltage 使用的 nominal span
```

因此软件实现时不要一边使用 `25.625 V raw span`，另一边又直接把 `16 LSB = 6.1 mV` 当成同一套未经校准的换算关系。

如果系统已经通过 `m/c` 做过校准，更适合使用系统实际有效的 `VSPAN_EFF` 进行换算。

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

定义有效 Divider：

```text
D = max(RCLK_DIV_REG, 1)
```

则稳态 Ramp step 的更新频率可按：

```text
F_STEP = F_RCLK / D
```

更新周期：

```text
T_STEP = D / F_RCLK
```

Ramp 每一步都需要经过 Calibration Engine。数据手册说明 calibration delay 约为 `1.2 us`，并给出 Divider = 1 时外部 RCLK 最大约 `833 kHz`：

```text
1 / 833 kHz ~= 1.2 us
```

因此在最快工作条件下，下一步的计算与当前输出 settling 是流水进行的。

### 6.8 理论 Ramp 斜率公式

平均数字 Ramp 斜率可以按：

```text
SR = Delta_V_STEP / T_STEP
```

代入前述关系：

```text
SR
 = (5.125 x VREF / 65536)
   x STEP_X1
   x (m + 1) / 65536
   x F_RCLK / D
```

即：

```text
SR(V/s)
 = 5.125 x VREF x STEP_X1 x (m + 1) x F_RCLK
   / (65536^2 x D)
```

换成 `V/us`：

```text
SR(V/us)
 = 5.125 x VREF x STEP_X1 x (m + 1) x F_RCLK
   / (65536^2 x D x 10^6)
```

如果软件已经使用经过系统校准后的有效 Force span `VSPAN_EFF`，可以简化成更实用的形式：

```text
Delta_V_STEP ~= VSPAN_EFF x STEP_X1 / 65536
```

```text
SR ~= VSPAN_EFF x STEP_X1 / 65536 x F_RCLK / D
```

这种写法更适合上位机根据“目标斜率”反算 Step Size 和 Divider。

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

因此项目中的寄存器选择算法建议：

> **按实际 `x1 Step -> m 校准 -> 实际电压 Step -> RCLK/Divider` 的链路计算目标 Ramp；不要用 datasheet 的 `0.775 V/us` 反推寄存器。**

同时，实际 DUT 节点电压还会受到 Force Amplifier slew、负载电容、电流限制、环路稳定性以及线路压降等模拟因素影响。

### 6.10 Ramp 启动延迟

Ramp Enable 后通常需要约：

```text
(2 x Divider + 2) 个 RCLK
```

才开始实际更新，并可能存在约 `+/-1 RCLK` 的启动不确定性。

这部分属于 Ramp 启动 latency，不应混入稳态每一步的 `T_STEP` 斜率计算，但在计算整段 Ramp 总时间时需要计入。

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
- FIN DAC `m/c` 校准参数；
- Ramp Step Size；
- RCLK Divider；
- 其他本次工作模式需要的参数。

### 8.3 设置起点和终点

```text
FIN DAC x1 = START_CODE
Ramp End Code = END_CODE
```

Ramp Start 没有独立寄存器，启动 Ramp 时当前 FIN `x1` 就是 Start Code。

需要注意：

> Start Code 和 End Code 都是 `x1` 域中的 code。若上位机输入的是实际电压，应依据当前 `m/c`、Offset DAC、VREF 和 DUTGND 的配置，将实际电压反算为对应的 `x1`。

### 8.4 先进入 ZERO_FORCE

如果采用从 0 V Ramp 到工作电压的上电方式，例如：

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
FIN DAC = 0 V 对应 x1
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

逐步更新 FIN x1；每一步新的 x1 都经过 Calibration Engine 转换成 x2 后再更新实际 DAC，直到目标值。

完整过程：

```text
OFF_HIZ
  |
  v
配置静态参数
  |
  v
FIN x1 = START
Ramp End = TARGET
  |
  v
ZERO_FORCE / START_FORCE
  |
  v
Ramp Enable
  |
  v
RAMP_ACTIVE
START -> ... -> TARGET
  |
  v
ON
```

### 8.6 不应先 Ramp 完再打开 Force Amplifier

如果：

```text
HW_INH = 0
FIN: START -> V_TARGET 完成 Ramp
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

被中断时，FIN DAC `x1` 停留在当时已经到达的值，并退出 Ramp Mode。

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

因此可以计算 Ramp 所需步数和预计时间。

完整步数近似为：

```text
N_STEP = ceil(abs(END - START) / STEP_X1)
```

稳态 Step 时间近似为：

```text
T_STEP = Divider / F_RCLK
```

整段时间估算时还需要加入 Ramp 启动内部延迟以及 RCLK 相位不确定性。

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
   | 是否立即更新由 LOAD 模式决定
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

### 12.5 GANG 并联输出

GANG 用于多颗 AD5560 并联提高输出电流。可采用 FV/FV 或 FV/FI；需要均流时优先采用 **Master FV + Slave FI**。

`DPS Register 2` 的 `GANGMODE[10:9]` 与内部开关关系如下：

| GANGMODE | 模式 | SW1 | SW2 | SW5 | SW6 |
|---|---|---|---|---|---|
| `00` | Master FV，电压复制 | b | a | a | OFF |
| `01` | Master FV，电流复制 | b | a | b | OFF |
| `10` | Slave FV | c | c | OFF | ON |
| `11` | Slave FI | c | b | OFF | ON |

`SW16` 不由 GANGMODE 控制。

FV/FI 的典型连接为：

```text
Master  GANGMODE = 01
MASTER_OUT = Master MI
       |
       v
Slave1  SLAVE_IN   GANGMODE = 11
         MASTER_OUT
       |
       v
Slave2  SLAVE_IN   GANGMODE = 11
         MASTER_OUT
       |
       v
...
```

Slave 的 `SW6 = ON` 用于把前级 GANG reference 继续传到下一颗，**不是重新用本 Slave 的测量电流生成新的参考**。

FV/FI GANG 需满足以下约束：

- Master 与所有 Slave 使用相同 Current Range，并保持 Rsense 及测量链路匹配；
- Master 与 Slave 的 MI Gain 必须一致，否则相同 `SLAVE_IN` 电压不再对应相同电流；
- Slave 的 Current Clamp 必须关闭。若 `CLEN/LOAD` 仍作为 CLEN，实际 Clamp Enable 为软件 `CLEN` 与硬件 CLEN 的 OR，因此应同时保证软件 `CLEN = 0`、CLEN pin = Low；
- Master Clamp 可以保留，但总 GANG 限流值只能近似理解为并联路数乘以 Master 电流，不应作为高精度总电流限制；
- Master SENSE 应 Kelvin 接到实际 DUT 节点；各器件 DUTGND 使用同一 DUT ground reference；
- Slave Compensation 使用最快响应设置，Master Compensation 按 DUT 负载条件配置；
- GANG reference 链路应尽量短，最后一级 `MASTER_OUT` 可不连接；Master 的 `SLAVE_IN` 不使用；
- `LOAD` 不能同步切换 `GANGMODE`。

进入或退出 GANG 时，正在改变 GANG 配置的 Slave 应保持 High-Z。典型进入顺序为：先关闭 Slave 输出并完成 Range、MI Gain、Clamp、Compensation 配置，再设置 Master=`01`、Slave=`11`，最后使能 Slave；退出时采用相反顺序，必要时先将 Master 输出降到安全电压。

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
  m / c
  Ramp Step
  RCLK Divider
  |
  v
SET_RAMP
  FIN x1 = START
  Ramp End = TARGET
  |
  v
START_FORCE
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

## 15. FPGA / 上位机计算建议

如果上位机接口直接使用：

```text
START_VOLTAGE
END_VOLTAGE
RAMP_RATE (V/us 或 mV/us)
```

建议内部按以下顺序换算：

```text
1. 根据当前 VREF / m / c / Offset DAC / DUTGND
   将 START_VOLTAGE、END_VOLTAGE 反算成 x1 code

2. START_CODE 写入 FIN DAC x1 (0x08)

3. END_CODE 写入 Ramp End Code (0x3E)

4. 根据目标 RAMP_RATE、当前 m、VREF 和 RCLK
   枚举/选择 STEP_X1 与 Divider

5. 写 Ramp Step Size (0x3F)
   写 RCLK Divider (0x40)

6. Force Amplifier 已处于 Ramp 起始电压后
   Write 0x41 = 0xFFFF 启动 Ramp
```

在已经完成系统标定的实现中，建议保存一个统一的有效电压换算关系，例如：

```text
VSPAN_EFF
或
x1_to_voltage_gain
```

上位机和 FPGA 都基于同一套校准参数计算，不要在不同模块中分别硬编码：

```text
16 LSB = 6.1 mV
25.625 V span
25 V span
```

这些不同口径，否则容易造成 Ramp 斜率和目标电压计算不一致。

---

## 16. 器件控制约束总结

1. 复位完成后先等待 `BUSY = High`，再开始寄存器配置；
2. FIN DAC 与 Force Amplifier Enable 是两个不同概念；
3. `SW_INH = 1` 且 `HW_INH = 1` 时 Force Amplifier 才允许工作；
4. `High-Z` 与主动输出 `0 V` 完全不同；
5. FIN DAC 的数字链路为 `x1 -> Calibration Engine(m/c) -> x2 -> actual DAC`；
6. `5.125` 是固定模拟 DAC amplifier gain，不能关闭或通过寄存器修改；
7. `VREF = 5 V` 时 raw DAC span 为 `25.625 V`，正常 Force 应区分 raw overrange span 与约 `25 V nominal span`；
8. `m` 改变 `x1 -> x2` 的数字增益，`c` 提供数字 offset correction；
9. `c register` 与独立的 `Offset DAC` 不是同一个 offset；
10. 默认 `LOAD = 0` 时，写 FIN x1 后经过 Calibration Engine，新的 x2 在内部处理完成后自动作用到实际 DAC；
11. LOAD 控制的是“已经准备好的内部新值什么时候真正生效”，不是额外的 FIN x1 预写寄存器；
12. LOAD 不负责 Power Enable，也不能启动 Ramp；
13. Programmable Slew Rate 和 Ramp Function 是两种不同的输出变化机制；
14. Ramp Step Size 直接作用于 FIN DAC `x1`，不是作用于 `x2`；
15. Ramp Start Code、End Code 和 Step Size 均属于 `x1` code 域；
16. 每一个新的 Ramp x1 都经过 Calibration Engine 生成 x2，再加载到实际 DAC；
17. `m` 和 `VREF` 会影响实际 Ramp 电压步长和斜率；`c`、Offset DAC、DUTGND 不影响相邻 Ramp Step 的电压差；
18. 使用 Ramp Function 给 DUT 上电时，Ramp 之前 Force Amplifier 必须已经作用于 DUT，通常先进入 Ramp Start 电压；
19. Ramp 只能通过 `0x41 = 0xFFFF` 启动；
20. Ramp 运行期间普通 SPI 操作受限，应在启动前完成相关配置；
21. AD5560 没有专用 `RAMP_DONE` 标志，FPGA 可依据已知参数计时，并在需要时读回 FIN x1 确认是否达到 End Code；
22. Ramp 期间 Alarm 可以导致 Ramp 中断；
23. 直接 `HW_INH/SW_INH` 禁止输出会进入 High-Z，不等于受控 Ramp Down；
24. 如果下电也要求受控斜率，应先 Ramp 到目标低电压（例如 0 V），再进入 High-Z；
25. 多颗器件的 Ramp 启动需要考虑 SPI 顺序 skew 与 RCLK 不确定性；
26. 多颗在线通道需要同步更新 DAC/Range/Compensation 时，LOAD 比单纯顺序 SPI 写更适合；
27. 项目级设计应根据实际 DUT 需求，从上述机制中选择唯一或少量最终控制路径，避免同时维护多套无用流程。

---

## 17. 参考资料

- Analog Devices, **AD5560 Rev.F Data Sheet**: https://www.analog.com/media/en/technical-documentation/data-sheets/AD5560.pdf
- Analog Devices EngineerZone, **Ramp control of AD5560**：关于 `833 kHz / 2032 LSB / 0.775 V/us` 的计算讨论。
