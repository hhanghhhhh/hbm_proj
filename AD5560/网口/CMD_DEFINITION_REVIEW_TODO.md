# CMD 协议与通信开发 TODO

> 更新：2026-10-21  
> 目标：**先将 CMD 协议交上位机同步开发；FPGA 优先实现 Config 配置与 Power Sequence 上下电，尽快进入联调。**  
> 正式协议：`design/comm/CMD_DEFINITION.md`、`design/comm/COMMUNICATION_PROTOCOL.md`。本文只追踪尚未完成的开发工作及已确认结论。

## 1. 已确认的协议原则

- UDP 一问一答：上位机收到当前命令响应后才发送下一条；Payload 上限 1024 Byte，各 DATA 命令单包 N 不再另行规定，上位机按格式自行计算。
- `CONFIG_DATA`、`POWER_SEQUENCE_DATA` 只将原始 Record/Word 按 OFFSET 写入 RAM，不在通信模块解释内部业务字段。
- `CONFIG_START`、`POWER_SEQUENCE_START` 均**先完成 RAM Image CRC 检查，再返回 CRC_OK；只有 CRC_OK=1 才请求 System Controller 启动**。响应不等整个配置/上下电流程执行完成。
- 因一问一答，**START 等待 CRC 回复期间不存在下一条上位机写 RAM 指令**，无需额外为这个阶段设计上位机并发访问协议。
- 但 START 已响应后，后台配置或 Sequence 仍可能在执行。FPGA 必须防止此时 RAM 被其他命令覆盖；若收到不允许执行的命令，返回 `INVALID_STATE`，不能返回成功但实际忽略写入/启动。
- CRC Image 字节顺序、大端传输和数据布局以正式协议及相应设计文档为准。告警/故障扩展暂不阻塞基础功能。

## 2. P0 — 完善 CMD 协议，交给上位机

| 状态 | 工作项 | 结果 |
|---|---|---|
| [x] | P0-1：定义常用 STATUS 错误码 | `0x00` 成功，`0x01` 未知 CMD，`0x02` 长度错误，`0x03` 参数/地址错误，`0x04` 状态不允许，`0x05` RAM CRC 错误 |
| [x] | P0-2：厘清 START 期间的 RAM 访问 | CRC 回复前上位机不发下一条；仅保留**回复后后台任务执行期间**的 FPGA RAM 写保护与状态检查 |
| [x] | P0-3：确定精简 SYSTEM_STATUS | `STATUS + SYS_STATE + CFG_RESULT + SEQ_RESULT + FAULT_VECTOR`；CFG/SEQ 最近结果使用固定枚举并锁存，便于轮询 |
| [x] | P0-4：引用 RAM Image 格式 | 简单链接 Config Manager、Power Sequence Engine 和 Alarm Handler 的设计文档，不重复展开结构 |
| [x] | P0-5：更新正式 `CMD_DEFINITION.md` | 已写入上述定义，并精简重复说明 |
| [ ] | **P0-6：将正式协议提供给上位机并同步确认** | 以上位机可直接实现 `0x10/0x11/0x20/0x21/0x41` 为首版范围；Alarm/Fault 命令为后续 |

**首版命令重点：** `CONFIG_DATA / CONFIG_START / POWER_SEQUENCE_DATA / POWER_SEQUENCE_START / SYSTEM_STATUS`。不再重复讨论单包最大 Record 数或已明确的 CRC 检查时机。

## 3. P1 — FPGA CMD 业务层实现

### 3.1 参考旧多相 Buck 工程

参考：`../多相buck/rtl/`（旧串口协议与业务框架）。

| 旧模块 | 借鉴内容 | 新项目的区别 |
|---|---|---|
| `cmd_dispatcher.v`、`cmd_dispatcher_defs.vh` | CMD 分发、上下文和 Payload RAM 地址选择 | CMD 分类与编码以 AD5560 新定义为准 |
| `config_application.v` | 同步读取请求 RAM、拼装 32-bit Record、按 OFFSET 写入、生成业务响应 | 不要旧 BUS/I2C_ADDR/FLASH/MODE 字段；接 Config CRC 和 System |
| `en_control_application.v` | 16-bit Word 拼装和 Sequence RAM 写入 | 新 PSE Header/Record/START 语义不同 |
| `error_response_generator.v`、`response_buffer.v` | STATUS 错误响应、多个业务响应复用一条 TX 路径 | 确保长响应写入期间来源不变 |
| `hbm_comm_top.v` | Parser → Dispatcher → Application → Response → TX 整体连接 | 只参考架构，不复制 UART/RS485/ADDR、I2C 逻辑 |

新工程已有 `网口/udp_frame_parser.v`、`网口/udp_tx_frame_builder.v`，直接复用这两个 UDP 帧模块；无需移植旧 UART `frame_parser.v/tx_frame_builder.v`。

### 3.2 实现任务

- [ ] **P1-1：CMD 分发与响应通路。** 将 UDP Parser 的 CMD/SEQ/LENGTH/Payload RAM 交给业务模块；统一错误码和 TX 响应。
- [ ] **P1-2：Config 业务。** 处理 `0x10/0x11` 的 RAM 写入、Image CRC 检查、启动请求和应答。
- [ ] **P1-3：Power Sequence 业务。** 处理 `0x20/0x21` 的 RAM 写入、MODE/CRC 参数、启动请求和应答。
- [ ] **P1-4：补齐顶层 PSE CRC 接口。** `power_sequence_engine.v` 已有 `i_seq_word_count / i_seq_expected_crc / i_seq_crc_start / o_seq_crc_done / o_seq_crc_ok`，但 `ad5560_top.v` 尚未接出。
- [ ] **P1-5：SYSTEM_STATUS 实现。** 向通信层提供 SYSTEM 状态，锁存 `cfg_done / seq_done` 及 abort 结果，输出最近一次 CFG/SEQ 执行状态。现有 System FSM 状态尚未作为外部接口输出。
- [ ] **P1-6：保护与收发闭环。** 数据完整/地址范围检查；任务执行时不能实际忽略 RAM 写入却回 SUCCESS；不允许状态下 START 返回错误；确认同步 RAM 延迟、TX done 和请求释放时机。

> **与上位机串行一问一答不矛盾：** 网络事务已结束不代表后台 Config/Sequence 已结束，仍须检查业务执行状态。

## 4. P2 — 优先 Config，再联调上下电

- [ ] **P2-1：基础通信验证。** 合法帧、帧 CRC 错误丢弃、长度/未知命令错误、CMD/SEQ 回显。
- [ ] **P2-2：Config 端到端。** 分包写 Config RAM → START Image CRC 正确/错误 → SPI 配置执行 → SYSTEM_STATUS 查询完成/中止。
- [ ] **P2-3：Power Sequence 端到端。** 分包写 RAM → START ON/OFF → Image CRC 检查 → Ramp 参数/Step 执行 → SYSTEM_STATUS 查询。
- [ ] **P2-4：关键边界。** RAM 写范围、错误数据长度、正在执行时重新写入、非法状态下启动。
- [ ] **P2-5：与上位机核对固定测试数据。** 大端 Record/Word、Image CRC、START 响应、状态轮询。
- [ ] **P2-6：上板调试。** 优先打通 Config 和 Power-Up/Power-Down。

> 当前 Power-Down Ramp 到 0 后的最终 `SW_INH=0` 仍待设计；PSE 的 `seq_done` 不等于模拟电压已稳定或完全断电。

## 5. P3 — 基础功能跑通后再扩展

- [ ] Alarm Result Read / Alarm Clear、故障器件定位与处理。
- [ ] FAULT_RESET、故障恢复/安全断电及最终 SW_INH 流程。
- [ ] UDP 请求去重、最近响应缓存（正式可靠重传前需要，特别是 START 命令）。
- [ ] 视调试需求决定是否加直接 AD5560 `REG_READ / REG_WRITE`、`DEVICE_INFO`。
- [ ] 深入的 Power RAM Image 结构校验、更多故障状态字段等按实际问题追加。

## 6. 下一步

1. 将 **`design/comm/CMD_DEFINITION.md` + `COMMUNICATION_PROTOCOL.md`** 交给上位机确认并同步开发（P0-6）。
2. FPGA 参照旧多相 Buck CMD 架构开始 P1，先实现 Config，再实现 Power Sequence 和最简 SYSTEM_STATUS。
3. 双方使用固定测试包联调，后续再处理 Alarm/Fault 的完整功能。

> 本轮修改范围：本 TODO 与 `design/comm/CMD_DEFINITION.md`；**没有修改 RTL，也没有 Git commit/push**。
