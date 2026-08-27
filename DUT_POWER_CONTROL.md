# 多板卡 DUT 电源控制架构

## 1. 目的

本文定义多板卡场景下 DUT 电源的同步上电、正常下电和故障联动关断框架。

系统约束：

- 共 20 个板卡挂在同一条 RS485 总线上；
- 每个板卡控制 128 路 EN，每一路 EN 视为一路电源；
- 一个 DUT 的多路电源可能分散在多个板卡；
- DUT 上电、下电存在时序要求，同步精度约为 1 ms；
- Master 为 PC，不参与实时故障保护闭环；
- 板卡间使用 `START_SYNC`、`FAULT_REQ`、`FAULT_IO` 三根公共硬件线。

设计目标：

- 正常上/下电由各板卡在统一起点下执行本地时序；
- 任意一路电源故障时，只关闭该 DUT 的全部电源，不影响其他 DUT；
- 故障联动完全由 FPGA 之间完成，不依赖 PC 实时响应；
- 跨板故障通知具有 ACK 和自动重试能力。

---

## 2. DUT 映射和本地时序

系统控制的一级逻辑对象为 DUT，而不是单独的板卡或 EN。

每个板卡保存本板的 DUT 映射：

```text
DUT_ID -> EN_MASK[127:0]
```

同一个 DUT 可以分布在多个板卡。每块板只需要知道该 DUT 在本板上的 EN，不需要知道其他板卡的接线。

每块板保存本地上电时序、正常下电时序以及故障关断状态。故障关断优先级高于正常时序。

---

## 3. 三根公共硬件线

### 3.1 START_SYNC

`START_SYNC` 用于正常上电/下电的统一 `T=0`。

正常动作前，PC 通过 RS485 将目标 DUT、动作类型和时序配置准备到相关板卡，并逐板确认 READY。准备完成后，由指定板卡产生 `START_SYNC` 有效沿，各板卡从同一事件开始执行已经准备好的本地时序。

RS485 负责配置和确认，`START_SYNC` 只负责实时同步。

### 3.2 FAULT_REQ

`FAULT_REQ` 用于故障总线仲裁和 BUSY 指示：

- High：故障总线空闲；
- Low：已有板卡取得故障总线所有权。

发生故障的板卡先完成本地 DUT 关断并记录 pending fault，再通过固定时隙仲裁竞争总线。仲裁成功后拉低 `FAULT_REQ`，并持续保持到本次故障帧、ACK 和必要重试结束。

`FAULT_REQ` 不表示故障状态是否清除。达到重试上限后必须释放总线，不能因为异常节点永久阻塞后续故障事务。

### 3.3 FAULT_IO

`FAULT_IO` 用于发送故障帧，并在帧结束后复用为固定时隙 ACK 通道。

`FAULT_IO` 不承担普通配置和状态通信。

---

## 4. 故障处理规则

本板检测到故障后：

```text
Local Fault
    |
    +--> 根据故障 EN 得到 DUT_ID
    +--> 立即关闭本板 DUT_MASK[DUT_ID]
    +--> 记录 pending fault
    +--> 等待 Fault Bus 仲裁
```

其他板卡收到完整合法的故障帧后，根据自己的 `DUT_MASK[DUT_ID]` 立即关闭本板该 DUT 的全部 EN。

约束：

- 本地关断不得等待跨板通信；
- DUT fault/KILL 必须为幂等操作；
- 即使本板该 DUT 的 mask 为 0，也必须正常接收并 ACK；
- 一个板卡同时存在多个 DUT fault 时分别记录 pending；每次总线事务只发送一个 DUT fault，事务结束后重新参与下一轮仲裁发送剩余 pending fault；
- 故障状态下不得由普通 `START_SYNC` 或普通控制重新打开该 DUT。

---

## 5. FAULT_IO 帧格式

FAULT_IO 使用固定波特率的 UART 风格异步串行格式：

```text
8N1：1 Start + 8 Data + No Parity + 1 Stop
```

每个字节内部按 UART 规则发送；多字节字段统一采用大端字节序。

故障帧固定 7 Byte，不设置 LENGTH：

| Byte | 字段 | 含义 |
|---|---|---|
| 0 | SOF | 固定 `0xA5` |
| 1 | SOURCE_ID | 故障发起板卡编号 |
| 2 | DUT_ID | 需要故障关断的 DUT |
| 3 | FAULT_CODE | 故障类型 |
| 4 | EVENT_ID | 故障事件编号，同一次重发保持不变 |
| 5 | CRC16_H | CRC 高字节 |
| 6 | CRC16_L | CRC 低字节 |

CRC 采用 `CRC-16/MODBUS`：

- Init：`0xFFFF`；
- Poly：`0xA001`（反射形式）；
- RefIn / RefOut：true；
- XorOut：`0x0000`；
- CRC 覆盖 `SOURCE_ID` 至 `EVENT_ID`，不包含 SOF 和 CRC 字节本身。

注意：这里只采用 CRC-16/MODBUS 的计算算法；CRC 在线路上的字节顺序仍遵守本项目大端规则，发送 `CRC16_H` 后发送 `CRC16_L`，不采用 Modbus RTU 常见的低字节先发顺序。

---

## 6. 已确定时序参数

当前第一版以稳定、可靠和调试余量优先，参数确定为：

```text
FAULT_IO_BAUD      = 250 kbit/s
bit_time           = 4 us
ARB_GUARD           = 4 bit_time   = 16 us
ARB_SLOT            = 2 bit_time   = 8 us
TURNAROUND_GAP      = 4 bit_time   = 16 us
ACK_SLOT            = 6 bit_time   = 24 us
ACK_ACTIVE          = 2 bit_time   = 8 us
MAX_RETRY           = 2            // 首次发送失败后最多重发 2 次
```

ACK slot 固定划分为：

```text
2 bit_time guard
2 bit_time ACK active（FAULT_IO 拉低）
2 bit_time guard
```

20 个节点分别使用 `ACK_SLOT[0]` ~ `ACK_SLOT[19]`。

所有故障总线时序统一由 `bit_time` 派生，不在协议中混用独立的微秒常数。

---

## 7. 多板卡故障仲裁

仲裁按 `BOARD_ID` 固定优先级执行。

基本规则：

1. `FAULT_REQ = Low` 时，所有板卡仲裁计数保持清零；存在 fault 的板卡只保留 pending 状态；
2. `FAULT_REQ = High` 且存在 pending fault 时，从头开始仲裁；
3. 所有板卡先等待 `ARB_GUARD`；
4. 板卡的竞争时刻为：

```text
ARB_GUARD + BOARD_ID * ARB_SLOT
```

5. 到达自身竞争时刻后，必须再次确认 `FAULT_REQ` 仍为 High，才能拉低 `FAULT_REQ` 并取得总线所有权；
6. 任意板卡检测到 `FAULT_REQ` 被其他节点拉低后，立即清零仲裁计数，保留 pending fault；
7. 当前事务结束、`FAULT_REQ` 重新变 High 后，仍有 pending fault 的板卡重新参与下一轮仲裁。

该仲裁为固定 Board ID 优先级，不保证故障严格按发生时间先后发送。

---

## 8. ACK 和重试

故障帧最后一个 Stop Bit 结束后：

```text
Fault Frame
    |
    +--> TURNAROUND_GAP
    +--> ACK_SLOT[0]
    +--> ACK_SLOT[1]
    +--> ...
    +--> ACK_SLOT[19]
```

每块板仅在自己的 ACK slot 内响应。ACK 在线路上的有效状态为主动拉低 `FAULT_IO`。

ACK 表示：

- 帧格式、SOF、CRC、DUT_ID 等检查通过；
- 本板已经完成该 DUT 的故障关断处理。

故障发起板自身 ACK 位可直接视为成功。发起方根据各 ACK slot 得到 `ack_bitmap[19:0]`。

存在未 ACK 节点时，保持当前 `FAULT_REQ` 所有权并重发同一 `EVENT_ID`。最多重发 2 次；仍失败则记录 missing ACK bitmap，结束当前事务并释放 `FAULT_REQ`。

---

## 9. 电气连接约束

### 9.1 FAULT_REQ / FAULT_IO

两根线均采用共享开漏方式：

- 总线空闲为 High；
- 任意节点只允许主动拉 Low 或释放为高阻，禁止主动驱动 High；
- 建议 FPGA 与公共总线之间使用外部开漏缓冲/驱动器，接收侧使用具有施密特特性的输入缓冲；
- 公共总线只设置一处主上拉，避免 20 块板分别安装强上拉造成等效阻值过低；
- 3.3 V 系统主上拉初值建议 `1.5 kOhm`，原理图可预留 `1 kOhm ~ 2.2 kOhm` 调整范围，最终依据实测上升时间确定；
- 各板预留的本地上拉默认不装或仅作为调试备选；
- 公共信号必须有可靠公共地参考，布线优先采用主干/背板方式并尽量缩短支路。

### 9.2 START_SYNC

`START_SYNC` 由唯一指定节点驱动，其余节点只作为输入，禁止多节点同时推挽驱动。建议使用缓冲后的单向同步信号，并定义明确的空闲电平。

---

## 10. 与 RS485 的职责划分

RS485 保持 PC Master、板卡 Slave 架构，负责：

- DUT/EN 映射配置；
- 上下电时序配置；
- ARM / READY；
- 状态和故障记录读取；
- 其他普通业务通信。

正常同步：

```text
RS485 逐板准备和确认
        +
START_SYNC 统一触发
```

故障同步：

```text
本地立即关断
        +
FAULT_REQ 仲裁 / BUSY
        +
FAULT_IO 故障帧
        +
固定时隙 ACK / 自动重试
```

PC 不参与故障关断实时闭环。

---

## 11. 安全约束

- 本板故障关断优先级最高；
- 跨板故障关断优先于正常上/下电时序；
- 只有完整合法的故障帧才能触发跨板 DUT 关断；
- 单个 DUT 故障不得影响其他 DUT；
- 未取得 `FAULT_REQ` 所有权的板卡不得在故障帧发送阶段驱动 `FAULT_IO`；
- `FAULT_REQ` 不得因 ACK 异常被永久占用；
- 协议第一版优先保证可靠性，不为缩短几十或几百微秒增加复杂机制。

---

## 12. 后续仍需结合硬件确认

以下内容不影响当前 RTL 架构，可在联调时根据实测结果调整：

- `FAULT_CODE`、`EVENT_ID` 的具体编码规则；
- `START_SYNC` 的具体脉宽和动作上下文管理；
- 主上拉最终阻值及是否需要增加串联阻尼；
- 实际线路长度、总线电容和噪声环境是否允许后续提高 FAULT_IO 波特率。

若无明确性能需求，第一版保持上述保守参数，不主动提高速度。
