# CMD 命令定义

## 1. 文档目的

本文档定义通信协议中的 CMD 分类和基本用途。

通信帧格式、CRC、数据格式等通用规则参考：

`COMMUNICATION_PROTOCOL.md`

设计原则：

- CMD 描述设备功能，不绑定 FPGA 内部寄存器实现。
- 请求和响应使用统一帧格式。
- 小数据采用请求/响应模式。
- 大数据采用分包传输方式。
- 复杂的数据组织和业务逻辑尽可能由上位机完成，FPGA 通信协议保持简单。

---

# 2. CMD 分类

## 2.1 参数 / 状态类

用于设备信息、参数读取、实时状态查询等。

典型命令：

| CMD | 功能 |
|---|---|
| GET_INFO | 获取设备信息 |
| READ_STATUS | 读取设备状态 |
| READ_REALTIME | 读取实时采样数据 |
| READ_PARAM | 读取参数 |
| WRITE_PARAM | 修改参数 |

特点：

- 数据量较小。
- 通常采用一次请求、一次响应。
- 实时数据建议一次返回完整快照，保证数据一致性。

---

# 2.2 控制类

用于设备运行控制。

典型命令：

| CMD | 功能 |
|---|---|
| START_OUTPUT | 开始输出 |
| STOP_OUTPUT | 停止输出 |
| RESET | 设备复位 |
| CLEAR_FAULT | 清除故障 |

特点：

- Payload 通常较小。
- 执行前需要检查设备当前状态。
- 必须返回执行结果。

---

# 2.3 大块配置数据类

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

# 2.4 在线升级类

用于 FPGA 固件或设备程序升级。

典型命令：

| CMD | 功能 |
|---|---|
| FW_BEGIN | 开始升级 |
| FW_DATA | 固件数据块 |
| FW_VERIFY | 固件校验 |
| FW_STATUS | 查询升级状态 |
| FW_ACTIVATE | 激活升级结果 |

设计原则：

- 固件数据采用分包传输。
- 支持完整校验后再切换运行版本。
- 升级过程与普通控制命令隔离。

FW_DATA 示例：

```text
Payload:

OFFSET   数据偏移
DATA     固件数据
```

---

# 2.5 批量读取类

用于一次读取多个状态或参数，减少通信次数。

典型命令：

| CMD | 功能 |
|---|---|
| READ_BLOCK | 批量读取数据 |
| READ_SNAPSHOT | 读取状态快照 |

应用场景：

- 周期性读取多个采样值。
- 上位机状态刷新。
- 批量读取配置参数。

设计原则：

- 一次返回多个相关数据。
- 对实时数据建议采用快照方式，保证数据来自同一时刻。

---

# 2.6 遥测类

| CMD | 请求 Payload | 成功响应 Payload | 功能 |
|---|---|---|---|
| `0x20 TELEMETRY_ENABLE` | `ENABLE_MASK(16)` | `STATUS(1)` | 设置 128 通道遥测使能 |
| `0x21 TELEMETRY_READ` | `READ_MASK(16)` | `STATUS(1) + DATA(6×N)` | 回读选中通道 |

- 位图为 128 位大端数据，bit n 对应 channel n。
- `channel[6:4]` 为 BUS，`channel[3:1]` 为设备，`channel[0]` 为 Rail。
- 回读按通道号递增排列；每通道为 `VOLTAGE(2) + CURRENT(2) + STATUS(2)`，各字段采用大端顺序。

---

# 3. 后续扩展规则

- 新增功能优先增加 CMD，不修改基础帧格式。
- CMD 编号按功能分类规划，避免随机分配。
- 不为了通用性提前增加当前项目不需要的 CMD、字段和状态。
- 新增 CMD 时必须明确：
  - 请求 Payload 格式。
  - 响应 Payload 格式。
  - 执行结果状态。
