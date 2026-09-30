# CMD 命令定义

## 1. 文档目的

本文档定义通信协议中的 CMD 分类和基本用途。

通信帧格式、CRC、数据格式等通用规则参考：

`COMMUNICATION_PROTOCOL.md`


# 3. CMD 分类（当前项目）

## 3.1 Config RAM / 配置执行

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x10 CONFIG_DATA` | `OFFSET(2) + DATA(4×N)` | `STATUS(1)` | 写 Config RAM |
| `0x11 CONFIG_START` | `CONFIG_LENGTH(2) + CRC16(2)` | `STATUS(1) + CRC_OK(1)` | 校验 Config RAM，校验通过后启动配置 |

约束：

- `OFFSET` 和 `CONFIG_LENGTH` 单位均为一个 32-bit Config Record。
- Config RAM 最大 1024 Record。
- `CONFIG_DATA` 只负责写 RAM；每个通信帧自身仍按 `COMMUNICATION_PROTOCOL.md` 做帧 CRC。
- `CONFIG_START` 的 `CRC16` 是整个 Config RAM Image 的 CRC-16/MODBUS，不是通信帧 CRC。
- CRC 覆盖 `RAM[0] ~ RAM[CONFIG_LENGTH-1]`；每个 32-bit word 按 `[31:24] → [23:16] → [15:8] → [7:0]` 顺序累计。
- Payload 中的 `CRC16` 字段按协议统一采用大端格式。
- 通信模块收到 `CONFIG_START` 后先向 Config Manager 发 `cfg_crc_start`，等待 `cfg_crc_done`。
- `cfg_crc_done` 到达后，将 `cfg_crc_ok` 作为 `CRC_OK` 返回；只有 `CRC_OK=1` 时，通信模块才向 System Controller 发 `cfg_start_req`。
- `CRC_OK=0` 时不启动 System Controller，也不会产生任何 Driver 配置命令。
- `CONFIG_START` 响应只表示 RAM Image CRC 检查结果以及是否已发起配置，不表示全部 SPI 配置已经完成。

---

## 3.2 Power Sequence RAM / 上下电执行

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x20 POWER_SEQUENCE_DATA` | `OFFSET(2) + DATA(2×N)` | `STATUS(1)` | 写 Power Sequence RAM |
| `0x21 POWER_SEQUENCE_START` | `MODE(1) + WORD_LENGTH(2) + CRC16(2)` | `STATUS(1) + CRC_OK(1)` | 校验 Power Sequence RAM 并启动上下电 |

约束：

- `OFFSET` 和 `WORD_LENGTH` 单位均为一个 16-bit word。
- `MODE=0` 表示 Power-Up，`MODE=1` 表示 Power-Down。
- Power Sequence RAM 当前规划为 2048 × 16 bit。
- `POWER_SEQUENCE_START` 的 `CRC16` 是整个 Power Sequence RAM Image 的 CRC-16/MODBUS，不是通信帧 CRC。
- CRC 覆盖 `RAM[0] ~ RAM[WORD_LENGTH-1]`；每个 16-bit word 按 `[15:8] → [7:0]` 顺序累计。
- Payload 中的 `CRC16` 字段按协议统一采用大端格式。
- 通信模块收到 `POWER_SEQUENCE_START` 后，先将 `WORD_LENGTH / CRC16` 提供给 Power Sequence Engine，并发出 `seq_crc_start`，等待 `seq_crc_done`。
- `seq_crc_done` 到达后，将 `seq_crc_ok` 作为 `CRC_OK` 返回；只有 `CRC_OK=1` 时，通信模块才携带 `MODE` 向 System Controller 发 `seq_start_req`。
- `CRC_OK=0` 时不启动 System Controller，也不会执行任何 Parameter / Ramp / Sequence 命令。
- `POWER_SEQUENCE_START` 响应只表示 RAM Image CRC 检查结果以及是否已发起上下电流程，不表示整个 Power-Up / Power-Down 已执行完成。

---

## 3.3 Alarm / Fault

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x30 ALARM_RESULT_READ` | `OFFSET(2) + LENGTH(2)` | `STATUS(1) + DATA(2×LENGTH)` | 读取 Alarm Result RAM |
| `0x31 ALARM_CLEAR` | `CLEAR_ALL(1)` | `STATUS(1)` | 清除 Alarm |
| `0x40 FAULT_RESET` | 无 | `STATUS(1)` | 清除系统 Driver fault 并恢复到 IDLE |
| `0x41 SYSTEM_STATUS` | 无 | `STATUS(1) + CFG_BUSY(1) + SEQ_BUSY(1) + ALARM_BUSY(1) + ALARM_CLEAR_BUSY(1) + FAULT_VECTOR(1)` | 查询当前系统状态 |

约束：

- Alarm Result RAM 的 `OFFSET / LENGTH` 单位均为一个 16-bit word。
- `CLEAR_ALL=0`：只清除最近一次 `device_fault_vector` 中置位的 Device。
- `CLEAR_ALL=1`：清除全部 128 个 Device，主要用于初始化预清除。
- `FAULT_VECTOR[7:0]` bit n 对应 SPI BUS n。
- 具体 STATUS 错误码后续统一定义；至少需要区分参数非法、当前状态不允许执行和 RAM CRC 校验失败。

