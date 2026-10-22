# CMD 命令定义

本文档定义 UDP 业务 CMD、Payload 和 STATUS。帧格式、SEQ、字节序及帧 CRC 统一参考 [COMMUNICATION_PROTOCOL.md](COMMUNICATION_PROTOCOL.md)。所有多字节字段均为**大端（高字节在前）**。

## 1. STATUS 错误码

所有响应 Payload 第一个字节为 `STATUS`。

| STATUS | 名称 | 含义 |
|---|---|---|
| `0x00` | SUCCESS | 命令成功 |
| `0x01` | UNKNOWN_CMD | 未定义 CMD |
| `0x02` | LENGTH_ERROR | Payload 长度或数据对齐错误 |
| `0x03` | PARAM_ERROR | 参数非法、RAM 地址/范围越界 |

## 2. Config RAM / 配置执行

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x10 CONFIG_DATA` | `OFFSET(2) + DATA(4×N)` | `STATUS(1)` | 写 Config RAM |
| `0x11 CONFIG_START` | `CONFIG_LENGTH(2) + CRC16(2)` | `STATUS(1) + CRC_OK(1)` | 校验 RAM Image，通过后启动配置 |

- `OFFSET`、`CONFIG_LENGTH` 均以 **32-bit Config Record** 为单位；Config RAM 最大 **1024 Record**。Record 的 BUS、Device、寄存器和数据字段见 [CONFIG_MANAGER_DESIGN.md](../CONFIG_MANAGER_DESIGN.md)。
- `CONFIG_DATA` 只写 RAM；`DATA` 为完整 Record 的连续字节，不在通信模块解析 Record 内部字段。
- `CONFIG_START` 的 `CRC16` 是 RAM Image 校验值，覆盖 `RAM[0] ~ RAM[CONFIG_LENGTH-1]`；每个 32-bit Record 按 `[31:24] → [23:16] → [15:8] → [7:0]` 顺序参与 CRC-16/MODBUS。
- 收到 `CONFIG_START` 后发起 `cfg_crc_start`，等待 `cfg_crc_done` 后返回 CRC 结果；**仅 CRC_OK=1 且当前状态允许**时向 System Controller 发 `cfg_start_req`。响应不等待全部 SPI 配置完成。

## 3. Power Sequence RAM / 上下电执行

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x20 POWER_SEQUENCE_DATA` | `OFFSET(2) + DATA(2×N)` | `STATUS(1)` | 写 Power Sequence RAM |
| `0x21 POWER_SEQUENCE_START` | `MODE(1) + WORD_LENGTH(2) + CRC16(2)` | `STATUS(1) + CRC_OK(1)` | 校验 RAM Image，通过后启动上下电 |

- `OFFSET`、`WORD_LENGTH` 均以 **16-bit word** 为单位；Power Sequence RAM 为 **2048 × 16 bit**。`MODE=0` 为 Power-Up，`MODE=1` 为 Power-Down。Header、Parameter Record、Step 格式见 [POWER_SEQUENCE_ENGINE_DESIGN.md](../POWER_SEQUENCE_ENGINE_DESIGN.md)。
- `POWER_SEQUENCE_DATA` 只写 RAM，不在通信模块解释时序参数。
- `POWER_SEQUENCE_START` 的 `CRC16` 覆盖 `RAM[0] ~ RAM[WORD_LENGTH-1]`；每个 16-bit word 按 `[15:8] → [7:0]` 顺序参与 CRC-16/MODBUS。
- 收到 START 后发起 `seq_crc_start`，等待 `seq_crc_done` 后返回 CRC 结果；**仅 CRC_OK=1 且当前状态允许**时携带 `MODE` 向 System Controller 发 `seq_start_req`。响应不等待整个 Power-Up/Power-Down 完成。

## 4. 系统状态查询

| CMD | 请求 Payload | 响应 Payload | 功能 |
|---|---|---|---|
| `0x41 SYSTEM_STATUS` | 无 | `STATUS(1) + SYS_STATE(1) + CFG_RESULT(1) + SEQ_RESULT(1) + FAULT_VECTOR(1)` | 查询系统状态与最近一次执行结果 |

**SYS_STATE**（1 Byte）：

| 值 | 状态 | 值 | 状态 | 值 | 状态 |
|---|---|---|---|---|---|
| `0x00` | IDLE | `0x01` | CONFIG | `0x02` | READY |
| `0x03` | SEQUENCE | `0x04` | ALARM | `0x05` | FAULT_HANDLE |
| `0x06` | ALARM_CLEAR | `0x07` | FAULT | `0x08` | FAULT_RESET_WAIT |

**CFG_RESULT / SEQ_RESULT**（各 1 Byte，共用编码）：`0x00` 未开始、`0x01` 执行中、`0x02` 已完成、`0x03` 已中止。复位后为未开始；新一轮任务实际启动时置执行中，完成/中止后保持结果，直到下一轮启动或复位。

**FAULT_VECTOR**（1 Byte）：bit n 对应 SPI BUS n 的系统锁存 Driver Fault。

`CFG_RESULT=已完成` 表示 Config Manager 配置结束并等到 Driver ready；`SEQ_RESULT=已完成` 表示 Power Sequence Engine 的时序流程结束，**不代表模拟电压已稳定到目标值**。

## 5. Alarm / Fault（后续完善）

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x30 ALARM_RESULT_READ` | `OFFSET(2) + LENGTH(2)` | `STATUS(1) + DATA(2×LENGTH)` | 读取 Alarm Result RAM |
| `0x31 ALARM_CLEAR` | `CLEAR_ALL(1)` | `STATUS(1)` | 清除 Alarm |
| `0x40 FAULT_RESET` | 无 | `STATUS(1)` | 清除系统 Driver fault 并恢复到 IDLE |

- Alarm Result RAM 的 `OFFSET / LENGTH` 单位均为一个 16-bit word；格式见 [ALARM_HANDLER_DESIGN.md](../ALARM_HANDLER_DESIGN.md)。
- `CLEAR_ALL=0`：清除最近一次 `device_fault_vector` 标记的 Device；`CLEAR_ALL=1`：清除全部 128 个 Device。
- `FAULT_RESET` 用于系统 Driver Fault 恢复，不代表器件 Alarm 已解除。


## 6. 遥测

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x50 TELEMETRY_ENABLE` | `ENABLE_MASK(16)` | `STATUS(1)` | 设置 128 通道后台测量使能 |
| `0x51 TELEMETRY_READ` | `READ_MASK(16)` | `STATUS(1) + DATA(6×N)` | 回读选中通道最新电压、电流 ADC 原始数据 |

- `ENABLE_MASK` 和 `READ_MASK` 均为 128-bit 大端位图，bit n 对应通道 n；`channel[6:4]` 为 `BUS_ID`，`channel[3:0]` 为 `DEVICE_ID`。
- `TELEMETRY_ENABLE` 设置参与后台测量的通道，bit=1 为使能、bit=0 为禁用；全 0 停止测量寄存器切换（不要求停止 AD4114 连续采样）。复位默认全 0，由上位机在上电结束后按需设置，不自动跟随上下电状态。
- `TELEMETRY_READ` 仅回读结果 RAM，不触发采样或等待新数据；按 `READ_MASK` 选中的通道号递增返回，每通道为 `VOLTAGE_RAW(3) + CURRENT_RAW(3)`，均为 AD4114 **24-bit 原始数据**，高字节在前，不附带有效标志。`N` 为选中通道数，最大 128，响应 Payload 最长 `1 + 128×6 = 769 Byte`。
- 结果 RAM 仅在相应电压/电流采样数据有效后更新，保留各通道最近一次有效值。上位机应在使能后完成首次有效 V/I 采集再读取；未完成首次采集或已禁用的通道，其缓存值不保证为本轮新数据。
