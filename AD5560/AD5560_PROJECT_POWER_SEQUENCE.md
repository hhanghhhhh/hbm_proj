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
- 多路 AD5560 的启动/停止先后顺序由 `Power Sequence Engine` 控制；
- `Power Sequence Engine` 由 `System Controller` 启动、暂停或终止；
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

## 5. Power Sequence Engine 与 System Controller

`Power Sequence Engine` 只负责按 Power Sequence RAM 产生寄存器事务，不负责系统工作模式或系统级 fault 判断。

`System Controller` 提供：

```text
seq_start
seq_pause
seq_abort
```

Power Sequence Engine 返回：

```text
seq_busy
seq_done
```

并向 System Controller 输出统一寄存器命令：

```text
seq_cmd_valid
seq_cmd_ready
seq_bus_id[2:0]
seq_rw
seq_device_id[3:0]
seq_reg_addr[6:0]
seq_wr_data[15:0]
```

当前记录完成：

```text
seq_cmd_valid && seq_cmd_ready
```

握手后即可继续下一条记录，不等待目标 Driver 的 SPI 事务真正执行完成。

不同 BUS 已接受的事务可以在 8 个 Driver 中并行执行；如果当前记录目标 Driver 仍忙，则停在当前记录等待。

---

## 6. Ramp 完成与 Alarm

AD5560 没有独立的 `RAMP_DONE` 引脚或 Ramp Complete 状态位。

FPGA 采用以下方式管理 Ramp：

1. 根据 Start Code、End Code、Step、RCLK Divider 和 RCLK 计算预计 Ramp 时间；
2. 到达预计结束时间后留出必要裕量；
3. 需要确认时可读回 `FIN DAC x1 (0x08)`，检查是否已经到达 End Code。

AD5560 不做后台状态寄存器轮询。

收到 `ALARM` 后，由 `System Controller` 暂停新的 Sequence 命令派发并启动 `Alarm Handler`，事件触发读取 Alarm / Fault Status 寄存器。已经被 Driver 接受的 SPI 事务不取消。

Alarm Handler 完成状态读取后，是否继续 Sequence 或转入故障处理由系统策略决定。

---

## 7. bus_fault 处理

Driver 的 `BUSY timeout` 等执行异常通过 `bus_fault` 上报给 `System Controller`。

发生 `bus_fault` 时：

```text
System Controller
      ↓
锁存 fault_vector
      ↓
seq_abort
      ↓
进入 FAULT 状态
```

Power Sequence Engine 收到 `seq_abort` 后立即停止继续派发新的时序记录，并退出 busy 状态。

故障需要立即关断输出时，可由更上层系统策略控制全局 `HW_INH` 进入 High-Z，不要求等待正常 Ramp Down 完成。

---

## 8. FPGA 实现边界

FPGA 侧主要关系为：

```text
System Controller
      │ seq_start / pause / abort
      ▼
Power Sequence Engine
      │ register transaction
      ▼
System Controller
      │ BUS_ID select
      ▼
AD5560 Driver × 8
      │
      ▼
SPI Master × 8
```

其中：

- AD5560 Driver 负责单颗器件的 SPI 事务和 BUSY 时序；
- Power Sequence Engine 负责多个通道之间的先后顺序和延时；
- System Controller 负责系统工作状态、Sequence 启停、Alarm 插入处理和系统级 fault；
- 单路 Ramp 斜率由 AD5560 的 Ramp Step、RCLK Divider 和 RCLK 决定；
- 多路之间的毫秒级时序由 Power Sequence Engine 的计数器/状态机决定。

---

## 9. 当前结论

本项目正常上下电统一采用：

```text
上电：High-Z -> Active 0 V -> Ramp Up -> Target Voltage

下电：Target Voltage -> Ramp Down -> Active 0 V -> High-Z
```

AD5560 负责每一路电压斜率，Power Sequence Engine 负责多路电源的约 `1 ms` 级时序协调，System Controller 负责系统级流程和异常处理。