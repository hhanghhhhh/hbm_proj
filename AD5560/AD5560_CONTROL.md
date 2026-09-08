# AD5560 控制与上电时序说明

## 1. 目的

本文整理 AD5560 在 DUT 供电场景下的基本控制方法，重点定义：

- SPI 配置与关键控制寄存器；
- `SW_INH` / `HW_INH` 对 Force Amplifier 的控制关系；
- Programmable Slew Rate 与 Ramp Function 的区别；
- 使用 Ramp Function 时的推荐上电顺序；
- 多颗 AD5560 的同步和多路电源时序控制方式；
- FPGA/控制器实现时应遵守的基本规则。

本文只描述 AD5560 自身操作，不讨论其他电源方案。

---

## 2. AD5560 控制接口概览

AD5560 是单通道可编程 DPS（Device Power Supply），主要通过 SPI 兼容的 3 线串行接口进行配置，接口时钟最高可到 50 MHz。

与 DUT 上电控制直接相关的硬件接口主要包括：

- `SYNC`：SPI 帧同步，低有效；
- `SCLK` / `SDI` / `SDO`：串行接口；
- `RESET`：器件复位；
- `BUSY`：开漏低有效，指示内部 DAC 校准/更新状态；
- `HW_INH/LOAD`：默认作为 Force Amplifier 硬件禁止输入，也可重配置为 `LOAD`；
- `CLEN/LOAD`：默认作为 Clamp Enable，也可重配置为 `LOAD`；
- `RCLK`：Ramp Function 使用的外部 Ramp Clock；
- `CLALM` / `KELALM` / `TMPALM`：相关故障告警输出。

器件复位或上电后，应先等待 `BUSY` 返回 High，确认内部复位/初始化完成，再执行后续配置。DUT 侧在 AD5560 尚未进入确定状态前应保持安全隔离或禁止输出。

---

## 3. FIN DAC、SW_INH 与 HW_INH 的关系

### 3.1 FIN DAC

`FIN DAC x1` 位于地址 `0x08`，决定 Force Voltage 的目标值。

需要明确：

> 写 FIN DAC 只是在修改目标电压，并不等同于打开或关闭 Force Amplifier。

因此可以在输出被禁止时预先写入 FIN DAC、Clamp、Current Range、Compensation 等参数。

### 3.2 SW_INH

`DPS Register 1`：地址 `0x02`。

- Bit15：`SW_INH`；
- `SW_INH = 1`：允许 Force Amplifier；
- `SW_INH = 0`：禁止 Force Amplifier。

上电默认 `SW_INH = 0`。

### 3.3 HW_INH

`HW_INH/LOAD` 默认作为硬件 Force Amplifier 控制输入。

当其工作在 `HW_INH` 模式时：

- `HW_INH = 0`：禁止 Force Amplifier，输出 High-Z；
- `HW_INH = 1`：允许 Force Amplifier 工作。

### 3.4 SW_INH 与 HW_INH 的组合关系

Rev.F 数据手册中，`SW_INH` 与 `HW_INH` 为 AND 关系：

```text
SW_INH = 1
    AND
HW_INH = 1
    |
    +--> Force Amplifier Enable
```

任意一个为 0，Force Amplifier 都被禁止。

因此推荐把两者分工理解为：

- `SW_INH`：软件层的 DPS Enable；
- `HW_INH`：FPGA/硬件层的实时 Enable / Inhibit。

典型做法是先通过 SPI 完成全部配置并令 `SW_INH = 1`，保持 `HW_INH = 0`；真正需要接通 DUT 时再由 FPGA 拉高 `HW_INH`。

---

## 4. 两种输出变化速度控制方式

AD5560 有两套不同机制，不能混淆。

### 4.1 Programmable Slew Rate

`DPS Register 2` 地址 `0x03`，`SR[2:0]` 位于 Bit[14:12]。

可选典型 Slew Rate：

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

该功能通过调整 Force DAC 输出放大器内部补偿来限制输出变化速度。

例如已经预配置：

```text
FIN DAC = 1.1 V
SW_INH = 1
HW_INH = 0
```

随后：

```text
HW_INH: 0 -> 1
```

Force Amplifier 开启并向 1.1 V 目标值变化，输出边沿受 Programmable Slew Rate、Current Range、负载电容及环路条件共同影响。

因此 Slew Rate 适合控制较快的 DUT 上/下电边沿，但不能把理论 `DeltaV / Slew Rate` 当作精确时序定时器。

### 4.2 Ramp Function

Ramp Function 的本质不同：

> Ramp 过程中 FIN DAC code 本身按步进逐渐增加或减小。

相关寄存器：

| 地址 | 功能 |
|---|---|
| `0x08` | FIN DAC x1，当前值也是 Ramp Start Code |
| `0x3E` | Ramp End Code |
| `0x3F` | Ramp Step Size |
| `0x40` | RCLK Divider |
| `0x41` | Enable Ramp，写 `0xFFFF` 启动 |
| `0x42` | Interrupt Ramp，写 `0x0000` 中断 |

Ramp Step Size 以 16 LSB 为基本步进单位；Ramp 更新节拍由外部 `RCLK` 与 Divider 共同决定。

使用 Ramp Function 时需要给 `RCLK` 输入时钟。数据手册给出的典型限制为：Divider = 1 时，RCLK 最大 833 kHz。

Ramp 通常在启动命令后约：

```text
(2 x Divider + 2) 个 RCLK
```

开始实际更新，受异步关系影响可能存在约 +/-1 个 RCLK 的不确定性。

---

## 5. Ramp Function 推荐 DUT 上电顺序

假设目标是让 DUT 从 0 V 按 Ramp 上升到 `V_TARGET`。

推荐顺序如下。

### 5.1 初始安全状态

```text
HW_INH = 0
SW_INH = 0
```

此时 Force Amplifier 禁止，DUT 输出保持 High-Z。

### 5.2 完成静态参数配置

在 Ramp 启动前完成所有需要的配置，包括但不限于：

- Current Range；
- Clamp / Current Limit；
- Compensation；
- Alarm；
- Ramp Step Size；
- RCLK Divider；
- 其他本次工作模式需要的控制项。

Ramp 开始后不应再依赖普通 SPI 写操作修改这些参数。

### 5.3 设置 Ramp 起点与终点

```text
FIN DAC x1 = 0 V        // Ramp Start
Ramp End Code = V_TARGET
```

Ramp Start 不是独立寄存器，Ramp 开始时 `FIN DAC x1` 的当前内容就是起点。

### 5.4 先使 Force Amplifier 工作在起始电压

先执行：

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

Force Amplifier 已经接管 DUT，但目标值仍是 Ramp 起始值 0 V。

推荐在这里留出必要的稳定时间，并检查关键 Alarm 状态。

### 5.5 启动 Ramp

向：

```text
Address = 0x41
Data    = 0xFFFF
```

写入 Enable Ramp 命令。

之后 AD5560 内部 Ramp Engine 根据：

```text
FIN DAC Start Code
Ramp End Code
Ramp Step Size
RCLK
RCLK Divider
```

自动逐步改变 FIN DAC，直到到达目标电压。

完整过程可理解为：

```text
High-Z
  |
  v
配置全部参数
  |
  v
FIN DAC = 0 V
Ramp End = V_TARGET
  |
  v
SW_INH = 1
  |
  v
HW_INH = 1
  |
  v
DUT 主动保持在 0 V
  |
  v
Write 0x41 = 0xFFFF
  |
  v
0 V -> ... -> V_TARGET
  |
  v
正常供电
```

### 5.6 不推荐先 Ramp 再打开 HW_INH

不应采用：

```text
HW_INH = 0
FIN DAC: 0 -> V_TARGET
Ramp 完成
HW_INH = 1
```

因为这样 DUT 在整个 Ramp 过程中没有连接到 Force Amplifier；最后 `HW_INH` 打开时仍然是 High-Z 直接切换到目标电压，Ramp 没有实现 DUT 软上电。

---

## 6. Ramp 运行期间的限制

进入 Ramp Mode 后，串行接口只接受 `Interrupt Ramp` 命令，其他普通命令会被忽略。

因此必须遵守：

> Ramp 启动前完成本次 Ramp 所需的全部工作参数配置。

Ramp 会在以下情况结束：

1. 到达 Ramp End Code；
2. 控制器发送 Interrupt Ramp；
3. 已使能的 Alarm 触发。

中断 Ramp 后，FIN DAC 停在当前值并退出 Ramp Mode，恢复正常控制。

---

## 7. Ramp 与硬件触发

AD5560 的 Ramp Function 不能由 `HW_INH`、`CLEN/LOAD` 或其他硬件引脚直接触发。

Ramp 的启动方式固定为软件命令：

```text
Write 0x41 = 0xFFFF
```

因此需要区分：

```text
HW_INH
    -> 控制 Force Amplifier 是否连接 DUT

Ramp Enable
    -> 控制 FIN DAC 是否开始逐步变化
```

二者功能完全不同。

---

## 8. 多颗 AD5560 的同步与多路时序

### 8.1 使用 HW_INH 控制同时 Enable

如果多个 AD5560 已经预配置好相同或各自独立的 FIN DAC，可以让多个器件共用一根 `HW_INH`：

```text
FPGA GROUP_EN
   |
   +--> AD5560 #0 HW_INH
   +--> AD5560 #1 HW_INH
   +--> AD5560 #2 HW_INH
   +--> ...
```

这样可以实现多路 Force Amplifier 的硬件级同时 Enable。

### 8.2 多电源轨顺序控制

对于多个电源轨，可以由 FPGA Power Sequencer 分别控制各路或各组 `HW_INH`：

```text
t = 0        Rail0 HW_INH = 1
t = T1       Rail1 HW_INH = 1
t = T2       Rail2 HW_INH = 1
```

这种方式适合：

- 普通硬件 Enable；
- 配合 Programmable Slew Rate 的快速软上电；
- 故障时快速拉低 `HW_INH` 禁止输出。

### 8.3 多颗器件的 Ramp 起始同步

Ramp 不能通过公共硬件触发线同时启动。

如果多颗 AD5560 分别通过 SPI 执行：

```text
Write 0x41 = 0xFFFF
```

各通道 Ramp 的起始时刻会包含 SPI 命令顺序造成的 skew，同时 Ramp 本身还有相对于 `RCLK` 的启动量化/异步不确定性。

因此在需要多路严格同步 Ramp 时，必须把以下两部分都纳入时序预算：

- 多颗器件 Ramp Enable SPI 命令之间的发送时间差；
- 每颗器件 Ramp 启动相对于 RCLK 的时间差。

如果系统只要求 us/ms 级的电源轨先后顺序，一般可由 FPGA 顺序发送 Ramp Enable 命令实现；如果要求极严格的多通道 Ramp 同步，需要单独评估是否满足 DUT 时序要求。

---

## 9. LOAD 功能

AD5560 没有独立的 LOAD 引脚，可以通过 System Control Register `0x01` 的 Bit[8:7]，将：

- `CLEN/LOAD`；或
- `HW_INH/LOAD`

其中一个重配置为 LOAD。

LOAD 用于同步多个 AD5560 的部分 DAC、Current Range、Compensation 等更新。

需要注意：

- 某个引脚配置成 LOAD 后，就不再执行其原来的 `CLEN` 或 `HW_INH` 功能；
- LOAD 不是 Ramp Start 硬件触发；
- Ramp 仍必须通过 `0x41 = 0xFFFF` 软件命令启动。

如果系统同时需要硬件快速禁止输出和 LOAD，优先考虑保留 `HW_INH` 的原始功能，将 `CLEN/LOAD` 用作 LOAD；具体取舍需结合 Clamp 控制需求确定。

---

## 10. FPGA 推荐控制状态机

对于单路使用 Ramp Function 的 DUT 上电，建议 FPGA/控制器按以下状态实现：

```text
RESET
  |
  v
WAIT_BUSY_HIGH
  |
  v
SAFE_INHIBIT
  SW_INH = 0
  HW_INH = 0
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
  FIN DAC = START
  Ramp End = TARGET
  |
  v
SW_ENABLE
  SW_INH = 1
  |
  v
HW_ENABLE
  HW_INH = 1
  |
  v
START_STABLE
  |
  v
RAMP_ENABLE
  Write 0x41 = 0xFFFF
  |
  v
RAMP_ACTIVE
  |
  +--> Alarm / Abort -> Fault Handling
  |
  v
POWER_ON
```

故障关断路径应尽量独立于 SPI 软件流程。需要快速禁止输出时，FPGA 可直接令：

```text
HW_INH = 0
```

使 Force Amplifier 进入 High-Z。

---

## 11. 实现约束总结

第一版实现建议固定以下规则：

1. 复位完成后先等待 `BUSY = High`，再开始寄存器配置；
2. 默认保持 `HW_INH = 0`，避免配置过程中 DUT 意外上电；
3. FIN DAC 与 Force Amplifier Enable 分开理解，写 DAC 不等于打开输出；
4. `SW_INH = 1` 且 `HW_INH = 1` 时 Force Amplifier 才允许工作；
5. 普通快速软启动优先使用 `HW_INH + Programmable Slew Rate`；
6. 需要慢速、可编程步进的电压变化时使用 Ramp Function；
7. 使用 Ramp Function 给 DUT 上电时，先让 Force Amplifier 工作在 Ramp Start 电压，再启动 Ramp；
8. Ramp 启动前完成 Current Range、Clamp、Compensation、Alarm 等全部配置；
9. Ramp 只能通过 `0x41 = 0xFFFF` 软件命令启动，不能由 LOAD/HW_INH 硬件触发；
10. Ramp 运行时除 Interrupt Ramp 外不发送其他 SPI 配置命令；
11. 多颗器件严格同步 Ramp 时必须计算 SPI 启动 skew 和 RCLK 启动不确定性；
12. 快速故障关断优先走 FPGA -> `HW_INH` 硬件路径，不依赖 SPI 实时响应。

---

## 12. 参考资料

- Analog Devices, **AD5560 Rev.F Data Sheet**: https://www.analog.com/media/en/technical-documentation/data-sheets/AD5560.pdf
- Analog Devices, **AD5560 Product Page**: https://www.analog.com/en/products/ad5560.html
- Analog Devices EngineerZone, **AD5560 Other FAQs**: https://ez.analog.com/automated-test-equipment/a/documents/c/ad5560-faqs/DO7529/other-faqs
