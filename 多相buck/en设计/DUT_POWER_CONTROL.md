# 多板卡 DUT 电源控制架构

## 1. 目的

本文定义多板卡场景下 DUT 电源的同步上电、正常下电和故障联动关断框架。

系统约束：

- 共 20 个板卡挂在同一条 PC RS485 总线上；
- 每个板卡控制 128 路 EN，每一路 EN 视为一路电源；
- 一个 DUT 的多路电源可能分散在多个板卡；
- 正常上电、正常下电为全系统统一动作，不按 DUT 单独启动；
- 正常上/下电同步精度约为 1 ms；
- Master 为 PC，不参与实时故障保护闭环；
- 板卡间使用 `START_SYNC`、`FAULT_REQ` 和独立差分 Fault Bus `FAULT_A/FAULT_B` 完成实时协同。

设计目标：

- 正常上/下电由各板卡在统一起点下执行本板 128 路 EN 的本地时序；
- 任意一路电源故障时，只关闭该 DUT 的全部电源，不影响其他 DUT；
- 故障联动完全由 FPGA 之间完成，不依赖 PC 实时响应；
- 跨板故障通知具有节点 ACK 和自动重试能力。

---

## 2. 本地配置数据

正常上/下电与故障保护使用两类独立配置。

### 2.1 正常上/下电时序

每块板保存本板 128 路 EN 的：

- `ON_SEQUENCE`；
- `OFF_SEQUENCE`。

正常时序不按 DUT 划分。PC 在系统启动前将每块板的 128 路 EN 时序配置完成，并逐板确认配置有效。

### 2.2 DUT 故障映射

每块板保存本板的 DUT 映射：

```text
DUT_ID -> EN_MASK[127:0]
```

同一个 DUT 可以分布在多个板卡。每块板只需要知道该 DUT 在本板上的 EN，不需要知道其他板卡的接线。

DUT mask 只用于故障关断和故障锁定，不参与正常全局上/下电时序的划分。

---

## 3. 板卡间实时硬件接口

### 3.1 START_SYNC

`START_SYNC` 是全系统正常电源目标状态和统一时序起点，采用持续电平：

- `START_SYNC = Low`：全系统正常下电目标；
- `START_SYNC = High`：全系统正常上电目标。

各板卡使用电平变化启动本地时序：

- `Low -> High`：所有板卡同时启动本板 `ON_SEQUENCE`；
- `High -> Low`：所有板卡同时启动本板 `OFF_SEQUENCE`。

因此 `START_SYNC` 的边沿作为所有板卡共同的 `T=0`，电平表示当前全局目标状态。

约束：

- `START_SYNC` 不携带 DUT_ID；
- 正常上/下电始终为全系统动作；
- `START_SYNC` 由 Board0 作为唯一输出驱动，其余板卡固定为输入；
- 采用普通单主推挽信号，不采用共享开漏；
- 总线安全默认状态为 Low，Board0 未配置或失效时应由硬件弱下拉保证 Low；
- 输入需做同步和抗毛刺处理，第一版建议新电平连续稳定约 `50 us` 后再确认变化；
- 本地配置无效时不得响应上电边沿，必须保持安全下电并锁存异常；
- FPGA 复位恢复后，即使当前 `START_SYNC = High`，也不得自动执行上电，必须等待新的有效 `Low -> High` 边沿。

正常下电通过 `High -> Low` 执行有序 `OFF_SEQUENCE`；故障下电不执行正常下电序列，直接按 DUT mask 紧急关断。

### 3.2 FAULT_REQ

`FAULT_REQ` 是低速共享开漏信号，只负责：

- 多板卡故障发送仲裁；
- Fault Bus BUSY / 所有权指示。

定义：

- `FAULT_REQ = High`：Fault Bus 空闲；
- `FAULT_REQ = Low`：已有板卡取得 Fault Bus 所有权。

发生故障的板卡先完成本地 DUT 关断并记录 pending fault，再通过固定时隙仲裁竞争总线。仲裁成功后拉低 `FAULT_REQ`，并持续保持到本次故障帧、ACK 和必要重试结束。

`FAULT_REQ` 不承担高速数据传输，其时序独立于 `FAULT_A/B` 波特率。

`FAULT_REQ` 不表示系统故障状态是否清除。达到重试上限后必须释放，不能因为异常节点永久阻塞后续故障事务。

### 3.3 FAULT_A / FAULT_B

`FAULT_A/FAULT_B` 是独立于 PC 通信 RS485 的差分 Fault Bus。

用途：

- 发送故障帧；
- 故障帧结束后作为各节点固定 ACK 时隙的物理通道。

所有节点使用 RS485 收发器挂在同一总线上：

- 非发送状态 `DE = 0`，节点只监听；
- 只有取得 `FAULT_REQ` 所有权的节点允许发送故障帧；
- ACK 阶段只有轮到自身 ACK 时隙的节点允许短时间 `DE = 1`；
- 其他所有节点必须保持 `DE = 0`，不得主动驱动 Idle 电平。

Fault Bus 不承担普通配置、查询或 PC 通信。

---

## 4. 故障处理规则

本板检测到故障后：

```text
Local Fault
    |
    +--> 根据故障 EN 得到 DUT_ID
    +--> 立即关闭本板 DUT_MASK[DUT_ID]
    +--> 锁存该 DUT 的 fault inhibit
    +--> 记录 pending fault
    +--> 等待 FAULT_REQ 仲裁
```

其他板卡收到完整合法的故障帧后，根据自己的 `DUT_MASK[DUT_ID]` 立即关闭本板该 DUT 的全部 EN，并锁存对应 fault inhibit。

故障锁定必须覆盖正常时序输出。概念上：

```text
actual_en = normal_or_debug_en & ~fault_inhibit_mask
```

因此即使 `START_SYNC` 仍为 High，或正常时序后续再次要求某路 EN 打开，处于 fault inhibit 的 DUT 也不得重新上电。

约束：

- 本地关断不得等待跨板通信；
- DUT fault/KILL 必须为幂等操作；
- 即使本板该 DUT 的 mask 为 0，也必须正常接收并 ACK；
- 一个板卡同时存在多个 DUT fault 时分别记录 pending；
- 每次 Fault Bus 事务只发送一个 DUT fault；当前事务结束后，仍有 pending fault 的板卡重新参与下一轮仲裁；
- 故障恢复必须经过独立故障清除流程，不能由 `START_SYNC` 自动清除。

---

## 5. Fault Bus 帧格式

Fault Bus 使用固定波特率的 UART 风格异步串行格式：

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

这里只采用 CRC-16/MODBUS 的计算算法；CRC 在线路上的字节顺序仍遵守本项目大端规则，发送 `CRC16_H` 后发送 `CRC16_L`，不采用 Modbus RTU 常见的低字节先发顺序。

---

## 6. 第一版时序参数

第一版优先稳定、可靠和调试余量，当前参数确定为：

```text
FAULT_BUS_BAUD      = 400 kbit/s
bit_time            = 2.5 us
REQ_RELEASE_GUARD   = 20 us
ARB_SLOT            = 10 us
TURNAROUND_GAP      = 10 us
ACK_SLOT            = 10 us
ACK_ACTIVE          = 5 us
MAX_RETRY           = 2      // 首次失败后最多重发 2 次
```

说明：

- `FAULT_REQ` 仲裁时序使用固定微秒参数，不与 Fault Bus `bit_time` 绑定；
- `FAULT_A/B` 数据发送使用 400 kbit/s；
- ACK 不发送 UART Byte，而是在固定时隙内发送短差分有效脉冲；
- 每个 `ACK_SLOT` 约为 `2.5 us guard + 5 us ACK active + 2.5 us guard`。

---

## 7. 多板卡故障仲裁

仲裁按 `BOARD_ID` 固定优先级执行。

基本规则：

1. `FAULT_REQ = Low` 时，所有板卡仲裁计数保持清零；存在 fault 的板卡只保留 pending 状态；
2. `FAULT_REQ = High` 且存在 pending fault 时，从头开始仲裁；
3. 所有板卡先等待 `REQ_RELEASE_GUARD`；
4. 板卡竞争时刻为：

```text
REQ_RELEASE_GUARD + BOARD_ID * ARB_SLOT
```

5. 到达自身竞争时刻后，必须再次确认 `FAULT_REQ` 仍为 High，才能拉低 `FAULT_REQ` 并取得总线所有权；
6. 任意板卡检测到 `FAULT_REQ` 被其他节点拉低后，立即清零仲裁计数，保留 pending fault；
7. 当前事务结束、`FAULT_REQ` 重新变 High 后，仍有 pending fault 的板卡重新参与下一轮仲裁。

该仲裁为固定 Board ID 优先级，不保证故障严格按发生时间先后发送。

`FAULT_REQ` 为低速开漏信号，允许其上升沿明显慢于 Fault Bus 数据边沿；但必须保证不同节点识别 `FAULT_REQ = High` 的时间偏差远小于 `ARB_SLOT = 10 us`。最终以整机实测波形确认裕量。

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

每块板仅在自己的 ACK slot 内响应。

ACK 规则：

- ACK 不发送完整 UART 字节；
- 节点在自身 `ACK_ACTIVE` 窗口内使能 RS485 Driver 并驱动固定 ACK 有效电平；
- 发送方此时释放总线并保持接收，根据各时隙形成 `ack_bitmap[19:0]`；
- ACK 时隙之外所有节点必须 `DE = 0`。

ACK 表示：

- 故障帧格式、SOF、CRC、DUT_ID 等检查通过；
- 本板已经完成该 DUT 的故障关断处理。

故障发起板自身 ACK 位可直接视为成功。

存在未 ACK 节点时，发起方保持当前 `FAULT_REQ` 所有权并重发同一 `EVENT_ID`。首次失败后最多重发 2 次；仍失败则记录 missing ACK bitmap，结束当前事务并释放 `FAULT_REQ`。

---

## 9. 时间预算

按当前参数：

### 9.1 最坏首次仲裁

Board19：

```text
20 us + 19 * 10 us = 210 us
```

### 9.2 故障帧

7 Byte、8N1：

```text
7 * 10 bit / 400 kbit/s = 175 us
```

### 9.3 ACK

```text
TURNAROUND_GAP = 10 us
20 * ACK_SLOT  = 200 us
```

因此 Board19 最坏首次正常事务约：

```text
210 + 175 + 10 + 200 = 595 us
```

正常情况下满足约 1 ms 级跨板故障联动目标。进入重试后允许总时间超过 1 ms，优先保证可靠送达。

---

## 10. 电气连接约束

### 10.1 START_SYNC

- Board0 唯一推挽输出，其余板卡固定输入；
- 建议 Board0 通过外部 Buffer/Driver 驱动公共线；
- 建议输出端预留约 `22~47 Ohm` 串联阻尼；
- 总线设置弱下拉，保证 Board0 未配置、复位或输出失效时默认 Low；
- 具体弱下拉可从 `4.7 kOhm ~ 10 kOhm` 范围结合硬件确认。

### 10.2 FAULT_REQ

- 共享开漏 / open-drain；
- 所有节点只允许拉 Low 或释放为高阻，禁止主动驱动 High；
- 公共总线设置主上拉；
- 由于该线只承担低速仲裁/BUSY，不要求达到 Fault Bus 数据速率；
- 接收端优先使用带施密特特性的输入；
- 上拉阻值最终以 20 板整机实测 `FAULT_REQ` 上升时间和节点 High 识别偏差确定。

### 10.3 FAULT_A / FAULT_B

- 使用独立 RS485 差分总线；
- 所有 20 个节点通过 RS485 收发器并联在同一主干；
- 非发送时节点必须关闭 Driver (`DE = 0`)；
- 主干两端按 RS485 规范设置终端匹配，具体阻值结合所选收发器和布线阻抗确定；
- 总线设置合适的 failsafe bias，确保所有 Driver 关闭时接收端得到稳定 Idle；
- 布线采用差分对、主干拓扑并尽量缩短支路；
- Fault Bus 与 PC 通信 RS485 为两套独立物理总线。

---

## 11. 与 PC RS485 的职责划分

PC RS485 保持 PC Master、板卡 Slave 架构，负责：

- 每块板 128 路 EN 的正常上/下电时序配置；
- DUT/EN mask 配置；
- READY / 配置状态确认；
- 状态和故障记录读取；
- 故障清除及其他普通业务通信。

正常同步：

```text
PC RS485 逐板配置和确认
        +
START_SYNC 电平变化统一触发
```

故障同步：

```text
本地立即关断
        +
FAULT_REQ 开漏仲裁 / BUSY
        +
FAULT_A/B 差分故障帧
        +
固定时隙 ACK / 自动重试
```

PC 不参与故障关断实时闭环。

---

## 12. 安全约束

- 本板故障关断优先级最高；
- 跨板故障关断优先于正常上/下电和调试控制；
- 只有完整合法的故障帧才能触发跨板 DUT 关断；
- 单个 DUT 故障不得影响其他 DUT；
- 未取得 `FAULT_REQ` 所有权的板卡不得发送故障帧；
- ACK 阶段未轮到自身时隙的板卡必须保持 RS485 Driver 关闭；
- `FAULT_REQ` 不得因 ACK 异常被永久占用；
- 第一版优先保证可靠性，不为缩短几十或几百微秒增加复杂机制。

---

## 13. 后续仍需结合硬件确认

以下内容不影响当前 RTL 架构，可在联调时根据实测结果调整：

- `FAULT_CODE`、`EVENT_ID` 的具体编码规则；
- `FAULT_REQ` 主上拉最终阻值；
- Fault Bus 收发器型号、终端和 failsafe bias 方案；
- 实际线路长度、支路长度和噪声环境是否允许后续提高 Fault Bus 波特率；
- `REQ_RELEASE_GUARD`、`ARB_SLOT`、`ACK_SLOT` 是否可在实测稳定后进一步缩短。

若无明确性能需求，第一版保持上述保守参数，不主动提高速度。
