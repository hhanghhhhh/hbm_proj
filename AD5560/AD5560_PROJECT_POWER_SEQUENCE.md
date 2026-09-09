# AD5560 项目上下电时序方案

## 1. 文档目的

本文只定义本项目采用的 AD5560 上下电方案。

AD5560 的器件机理、寄存器说明、`LOAD`、`SW_INH/HW_INH`、Alarm、Calibration Engine 等详细内容见：

- [`AD5560_CONTROL.md`](./AD5560_CONTROL.md)
- [`AD5560_SOFTWARE_GUIDE.md`](./AD5560_SOFTWARE_GUIDE.md)

本文不重复这些通用说明。

---

## 2. 已确定方案

本项目采用：

> **AD5560 Ramp Function 控制单路电压的上升/下降斜率，FPGA 负责多个 AD5560 之间的上下电先后时序。**

约束：

- 不使用 Programmable Slew Rate 作为正常上下电斜率控制手段；
- 不使用 `LOAD` 作为正常上下电触发手段；
- Ramp 由 FPGA 通过 SPI 写 `0x41 = 0xFFFF` 启动；
- 多路 AD5560 的启动/停止先后顺序由 FPGA 本地状态机控制；
- 多路时序控制精度目标约为 `1 ms`；
- `RCLK` 由 FPGA 提供，各 AD5560 可共享；
- Ramp Step、RCLK Divider、目标电压等参数在 Ramp 启动前完成配置。

---

## 3. 上电流程

正常 OFF 状态定义为 Force Amplifier High-Z。

某一路轮到上电时：

```text
OFF_HIZ
   |
   v
FIN DAC = 0 V
Ramp End = V_TARGET
Ramp Step / Divider 已配置
   |
   v
SW_INH = 1
HW_INH = 1
   |
   v
PRE_RAMP：DUT 被主动驱动到 0 V
   |
   v
Write 0x41 = 0xFFFF
   |
   v
RAMP_UP：0 V -> V_TARGET
   |
   v
ON
```

FPGA 按各路配置的延迟依次启动 Ramp，例如：

```text
t = 0 ms      Start Ramp CH0
t = 1 ms      Start Ramp CH1
t = 2 ms      Start Ramp CH2
...
```

实际各路延迟应由配置参数决定，`1 ms` 为当前目标时序精度，不要求固定每路间隔必须为 1 ms。

---

## 4. 下电流程

正常下电采用 Ramp Down，不直接从工作电压切到 High-Z。

```text
ON
 |
 v
设置 Ramp End = 0 V
 |
 v
Write 0x41 = 0xFFFF
 |
 v
RAMP_DOWN：V_TARGET -> 0 V
 |
 v
ZERO_FORCE
 |
 v
HW_INH = 0
或 SW_INH = 0
 |
 v
OFF_HIZ
```

FPGA 按项目定义的下电顺序和延迟逐路执行，时序控制精度同样按约 `1 ms` 设计。

---

## 5. Ramp 完成与异常处理

AD5560 没有独立的 `RAMP_DONE` 引脚或 Ramp Complete 状态位。

FPGA 采用以下方式管理 Ramp：

1. 根据 Start Code、End Code、Step、RCLK Divider 和 RCLK 计算预计 Ramp 时间；
2. 到达预计结束时间后留出必要裕量；
3. 需要确认时读回 `FIN DAC x1 (0x08)`，检查是否已经到达 End Code；
4. Ramp 期间若 Alarm 触发，则按 Ramp Abort / Fault 处理，不再按正常完成流程继续。

故障需要立即关断输出时，可直接通过 `HW_INH = 0` 进入 High-Z，不要求等待正常 Ramp Down 完成。

---

## 6. FPGA 实现边界

FPGA 侧至少需要包含：

```text
AD5560 SPI Transaction Controller
        |
        +-- Register Configuration
        |
        +-- Ramp Controller
        |
        +-- Multi-Channel Power Sequencer
        |
        +-- Alarm / Fault Handling
```

其中：

- Ramp Controller 管理单颗 AD5560 的 Ramp Up / Ramp Down；
- Power Sequencer 只负责多个 AD5560 之间的先后顺序和延时；
- 单路 Ramp 斜率由 AD5560 的 Ramp Step、RCLK Divider 和 RCLK 决定；
- 多路之间的毫秒级时序由 FPGA 计数器/状态机决定。

---

## 7. 当前结论

本项目正常上下电统一采用：

```text
上电：High-Z -> Active 0 V -> Ramp Up -> Target Voltage

下电：Target Voltage -> Ramp Down -> Active 0 V -> High-Z
```

AD5560 负责每一路电压斜率，FPGA 负责多路电源的约 `1 ms` 级时序协调。