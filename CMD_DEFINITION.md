# CMD 命令定义

## 1. 文档目的

本文档定义通信协议中的 CMD 分类和基本用途。

通信帧格式、CRC、数据格式等通用规则参考：

`COMMUNICATION_PROTOCOL.md`

---

# 2. CMD 分类

# 2.1 大块配置数据类

系统包含 8 条独立 I2C 总线，每路各有配置 RAM、结果 RAM 和配置执行模块。

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x10 CONFIG_DATA` | `BUS(1) + OFFSET(2) + DATA(4×N)` | `STATUS(1)` | 写配置 RAM |
| `0x11 CONFIG_START` | `BUS(1) + I2C_ADDR(1) + CONFIG_LENGTH(2) + STORE_FLASH(1) + CONFIG_MODE(1)` | `STATUS(1)` | 启动配置 |
| `0x12 CONFIG_STATUS` | 无 | `STATUS(1) + OK(1)` | 查询 8 条 I2C 总线状态 |
| `0x13 CONFIG_RESULT_READ` | `BUS(1) + OFFSET(2) + LENGTH(2)` | `STATUS(1) + DATA(2×LENGTH)` | 读取结果 RAM |

约束：

- `BUS` 取值为 0～7，多字节字段采用大端顺序。
- `CONFIG_DATA` 的 `OFFSET` 单位为一条 32 位配置记录，`DATA` 长度必须是 4 字节的整数倍。
- `CONFIG_START` 的 `CONFIG_LENGTH` 单位为 32 位配置记录；成功响应表示启动请求已接收，不表示配置已经完成。
- `CONFIG_STATUS` 的 `OK[7:0]` 分别对应 BUS7～BUS0，bit 为 1 表示对应 I2C 正常。
- `CONFIG_RESULT_READ` 的 `OFFSET` 和 `LENGTH` 单位均为一个 16 位结果项；`LENGTH` 为 1～1023，且 `OFFSET + LENGTH <= 1024`。建议在配置完成后读取。

---

# 2.2 遥测类

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x20 TELEMETRY_ENABLE` | `ENABLE_MASK(16)` | `STATUS(1)` | 设置 128 通道遥测使能 |
| `0x21 TELEMETRY_READ` | `READ_MASK(16)` | `STATUS(1) + DATA(6×N)` | 回读选中通道 |

- 位图为 128 位大端数据，bit n 对应 channel n。
- `channel[6:4]` 为 BUS，`channel[3:1]` 为设备，`channel[0]` 为 Rail。
- 回读按通道号递增排列；每通道为 `VOLTAGE(2) + CURRENT(2) + STATUS(2)`，各字段采用大端顺序。

---

# 2.3 EN 控制类

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x30 DEBUG_EN_WRITE` | `EN_STATE(16)` | `STATUS(1)` | 直接设置 128 路 EN 状态 |
| `0x31 EN_SEQUENCE_DATA` | `OFFSET(2) + DATA(2×N)` | `STATUS(1)` | 写入 EN 时序参数 |
| `0x32 EN_SEQUENCE_START` | `SEQUENCE_ID(1)` | `STATUS(1)` | 启动指定 EN 时序 |

- `EN_STATE` 为 128 位大端数据，bit n 对应 EN(n+1)。
- 当前仅使用低 112 位控制 EN1～EN112，高 16 位保留并忽略。
- 收齐完整位图后一次更新全部 EN 输出。
- `OFFSET` 和 `DATA` 均以 16 位为单位，多字节字段采用大端顺序。

