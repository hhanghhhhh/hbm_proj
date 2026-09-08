# 多板卡 DUT 电源控制整体流程说明

> 本文用于说明整个多板卡电源控制系统如何工作，重点解释各硬件通道分别做什么，以及正常上电、正常下电、故障关断时各模块之间如何配合。
>
> 具体协议参数和 RTL 约束以 `DUT_POWER_CONTROL.md` 为准。

## 1. 系统要解决的问题

系统共有 20 块板卡，每块板控制 128 路 EN。

一个 DUT 的多路电源可能分散在不同板卡，因此需要同时解决两个问题：

1. 正常上电/下电时，20 块板卡要在同一个时间起点执行各自的 EN 时序；
2. 任意一路电源故障时，要把该 DUT 分散在所有板卡上的电源都关掉，但不能影响其他 DUT。

PC 通过主 RS485 管理整个系统，但 PC 不承担实时故障保护，因此实时同步和故障传播由 FPGA 之间完成。

---

## 2. 整体架构

```text
                          PC Master
                             |
                             | 主 RS485
                             | 配置 / 查询 / READY / 故障清除
                             v
        +--------------------+--------------------+
        |                    |                    |
      Board0               Board1              Board19
        |                    |                    |
        |<-------------- START_SYNC ------------>|
        |<-------------- FAULT_REQ ------------->|
        |<=========== FAULT_A / FAULT_B =========>|
        |            专用差分 Fault Bus           |
        |                    |                    |
     128 x EN             128 x EN             128 x EN
```

板间实时控制使用三类硬件通道：

```text
START_SYNC      : 正常全系统上/下电同步
FAULT_REQ       : 故障仲裁 + BUSY
FAULT_A/B       : RS485 差分故障数据 + ACK
```

其中 `FAULT_A/B` 是一对差分线，因此物理上占两根导线。

主 RS485 不承担实时同步和实时故障传播。

---

## 3. 每块板内部保存什么

每块板主要保存两类数据。

### 3.1 正常上/下电时序

每块板保存本板 128 路 EN 的：

```text
ON_SEQUENCE
OFF_SEQUENCE
```

它描述本板 128 路 EN 的正常动作顺序，不按 DUT 划分。

例如：

```text
Board3 ON_SEQUENCE

T=0 ms      EN0、EN3
T=2 ms      EN8
T=5 ms      EN21、EN22
...
```

其他板卡保存自己的本地 sequence。

所有板卡 sequence 的时间基准都从同一个 `START_SYNC` 边沿开始，因此能够实现跨板同步。

### 3.2 DUT mask

每块板同时保存：

```text
DUT_ID -> EN_MASK[127:0]
```

例如 DUT3 的电源分布在 Board0、Board7 和 Board11：

```text
Board0  DUT3_MASK = 本板属于 DUT3 的 EN
Board7  DUT3_MASK = 本板属于 DUT3 的 EN
Board11 DUT3_MASK = 本板属于 DUT3 的 EN
```

每块板只需要知道自己的 mask，不需要知道其他板卡的具体接线。

该 mask 不参与正常上电顺序，只用于 DUT 故障时的快速关断和故障锁定。

---

## 4. START_SYNC 是干什么的

`START_SYNC` 是一个持续电平信号，由 Board0 作为唯一驱动节点，其余板卡只作为输入。

```text
Low  = 系统正常目标为全部下电
High = 系统正常目标为全部上电
```

真正触发 sequence 的是边沿：

```text
Low -> High : 所有板卡启动 ON_SEQUENCE
High -> Low : 所有板卡启动 OFF_SEQUENCE
```

因此它同时承担两个作用：

1. 电平表示系统当前正常目标状态；
2. 边沿提供所有板卡共同的 `T=0`。

### 正常上电

```text
PC
 |
 | 主 RS485 下发各板 ON_SEQUENCE / OFF_SEQUENCE
 v
20 块板保存配置
 |
 | PC 逐板查询
 v
所有板 READY
 |
 v
Board0: START_SYNC Low -> High
 |
 +----------+----------+----------+
 v          v          v          v
Board0    Board1      ...       Board19
ON_SEQ    ON_SEQ                ON_SEQ
T=0       T=0                   T=0
```

### 正常下电

```text
Board0: START_SYNC High -> Low
 |
 +----------+----------+----------+
 v          v          v          v
Board0    Board1      ...       Board19
OFF_SEQ   OFF_SEQ               OFF_SEQ
T=0       T=0                   T=0
```

正常上/下电是整机动作，不按 DUT 单独启动。

---

## 5. DUT 故障时发生什么

假设 Board7 的某一路 EN 发生故障，并确定它属于 DUT3。

第一步永远是本板立即关断，不等待任何板间通信：

```text
Board7 Local Fault
      |
      +--> 查到 DUT_ID = 3
      |
      +--> DUT3_MASK 本板立即关闭
      |
      +--> 锁存 DUT3 fault inhibit
      |
      +--> 记录 pending fault
```

然后 Board7 参与 Fault Bus 仲裁，把 `KILL DUT3` 发送给其他板卡。

同一板卡如果同时存在多个 DUT fault，则分别记录 pending；一次 Fault Bus 事务只发送一个 DUT fault，结束后重新参与下一轮仲裁。

---

## 6. FAULT_REQ 是干什么的

`FAULT_REQ` 是一根低速共享开漏线，只负责：

```text
故障仲裁
+
Fault Bus BUSY 指示
```

它不传输故障数据。

定义：

```text
High = Fault Bus 空闲
Low  = 某块板已经获得 Fault Bus 所有权
```

因为 `FAULT_REQ` 只用于低速仲裁，所以即使 20 个节点并联后开漏释放上升沿较慢，也不要求达到 `FAULT_A/B` 的数据速率。

仲裁时间独立于 Fault Bus 的 RS485 波特率。当前思路按固定时间窗口处理，例如：

```text
REQ_RELEASE_GUARD ≈ 20 us
ARB_SLOT          ≈ 10 us
```

某板存在 pending fault 时：

```text
FAULT_REQ = High
      |
      +--> 等待 REQ_RELEASE_GUARD
      |
      +--> 等待 BOARD_ID * ARB_SLOT
      |
      +--> 再次确认 FAULT_REQ 仍为 High
      |
      +--> 拉低 FAULT_REQ，获得 Fault Bus 所有权
```

其他等待中的板一旦检测到 `FAULT_REQ = Low`：

```text
仲裁计数清零
保留 pending fault
等待当前事务结束
```

当前事务结束后，发起方释放 `FAULT_REQ`。仍有 pending fault 的板卡在 `FAULT_REQ` 重新稳定为 High 后，从头参与下一轮仲裁。

因此开漏 `FAULT_REQ` 的关键不是上升沿必须很快，而是：

```text
各板对 High 的识别时间差
必须明显小于 ARB_SLOT
```

通过足够的 release guard 和仲裁 slot 留出裕量。

---

## 7. FAULT_A/B 是干什么的

真正的故障数据不再使用单端开漏 `FAULT_IO`，而使用独立的一对 RS485 差分线：

```text
FAULT_A
FAULT_B
```

20 块板各自配置一个 RS485 收发器。

平时：

```text
所有节点 DE = 0
所有节点监听总线
```

仲裁获胜节点：

```text
FAULT_REQ 拉 Low
      |
      +--> DE = 1
      +--> 通过 FAULT_A/B 发送 Fault Frame
```

其他节点始终保持：

```text
DE = 0
只接收
```

这样高速数据部分由 RS485 差分收发器主动驱动，不再受到 20 节点开漏 RC 上升时间的限制。

当前 Fault Frame 仍保持固定 7 Byte：

```text
SOF
SOURCE_ID
DUT_ID
FAULT_CODE
EVENT_ID
CRC16_H
CRC16_L
```

CRC 使用 CRC-16/MODBUS 计算，多字节字段按项目统一规则采用大端。

当前讨论的 Fault Bus 速率为：

```text
400 kbit/s
```

该速率后续可根据实际线路和收发器测试调整，不影响仲裁和协议结构。

---

## 8. 其他板收到 Fault Frame 后做什么

例如收到：

```text
DUT_ID = 3
```

每块板立即：

```text
查 DUT3_MASK
    |
    +--> 关闭本板 DUT3 对应 EN
    +--> 锁存 DUT3 fault inhibit
    +--> 准备在自己的 ACK slot 回应
```

即使某块板：

```text
DUT3_MASK = 0
```

也必须正常 ACK，因为 ACK 表示：

> 本板正确收到该故障事件并完成处理。

故障关断不运行正常 `OFF_SEQUENCE`，而是直接按 DUT mask 紧急关闭。

---

## 9. ACK 是怎么工作的

ACK 仍采用固定 Board ID 时隙，不发送完整 UART ACK byte。

原因是 ACK 只需要表达一个信息：

```text
“这个节点已经正确收到并处理”
```

Board ID 已经由 ACK 所在的时间位置隐式表示，因此没有必要再次发送地址或完整字节。

故障帧发送完成后，发起方释放 RS485 驱动：

```text
DE_sender = 0
```

经过固定 Turnaround 后进入 20 个 ACK slot：

```text
Fault Frame
    |
    +--> Turnaround
    |
    +--> ACK_SLOT[0]
    +--> ACK_SLOT[1]
    +--> ...
    +--> ACK_SLOT[19]
```

当前 400 kbit/s 下：

```text
bit_time = 2.5 us
ACK_SLOT = 4 bit_time = 10 us
```

每个 slot 暂按：

```text
1 bit guard
2 bit ACK active
1 bit guard
```

即：

```text
|<--------- 10 us --------->|

| 2.5 us |  5 us   | 2.5 us |
| guard  | ACK有效 | guard  |
```

轮到某块板 ACK 时：

```text
DE = 1
DI = 固定 ACK 电平
保持约 5 us
DE = 0
```

其余时间所有节点必须：

```text
DE = 0
```

不能主动驱动 Idle，避免两个 RS485 Driver 因时序重叠互相对打。

故障发起方在 ACK 阶段保持自己的 Driver 关闭、Receiver 开启，并在每个固定 slot 中间采样，最终形成：

```text
ack_bitmap[19:0]
```

---

## 10. ACK 失败和重试

如果全部节点 ACK：

```text
事务完成
FAULT_REQ 释放为 High
```

如果存在未 ACK 节点：

```text
FAULT_REQ 继续保持 Low
      |
      +--> 重发同一 EVENT_ID 的 Fault Frame
      +--> 再次进入 20 个 ACK slot
```

首次失败后允许有限次数重试。

如果达到重试上限仍失败：

```text
记录 missing ACK bitmap
      |
      +--> 结束当前事务
      +--> 释放 FAULT_REQ
```

不能因为一个异常节点永久占用 Fault Bus，否则后续其他 DUT fault 将无法传播。

---

## 11. 当前一次 Fault 事务的大概时间

以当前讨论值估算：

```text
Fault Bus         = 400 kbit/s
bit_time          = 2.5 us
REQ_RELEASE_GUARD = 20 us
ARB_SLOT          = 10 us
ACK_SLOT          = 10 us
```

7 Byte UART 8N1 Fault Frame：

```text
7 * 10 bit * 2.5 us = 175 us
```

20 个 ACK slot：

```text
20 * 10 us = 200 us
```

最低优先级 Board19 的首次仲裁约：

```text
20 us + 19 * 10 us = 210 us
```

再加约 10 us Turnaround，一次最坏首次完整事务约：

```text
210 + 175 + 10 + 200 ≈ 595 us
```

因此第一轮正常完成仍有较大的 1 ms 内时间裕量；如果进入重试，可以允许总时间超过 1 ms，以可靠传播故障为优先。

---

## 12. START_SYNC 和 Fault 谁优先

Fault 永远优先。

例如当前：

```text
START_SYNC = High
```

表示系统正常目标仍然是 ON。

这时 DUT3 fault：

```text
DUT3 fault inhibit = 1
```

即使 `START_SYNC` 一直保持 High，也不能重新打开 DUT3。

概念上：

```text
normal_sequence_en
       |
       v
   AND NOT fault_inhibit_mask
       |
       v
    actual EN
```

因此可能出现：

```text
START_SYNC = High

DUT0 = ON
DUT1 = ON
DUT2 = ON
DUT3 = FAULT / OFF
DUT4 = ON
...
```

故障 DUT 被隔离，其他 DUT 不受影响。

---

## 13. FPGA 复位时如何处理

如果系统已经上电：

```text
START_SYNC = High
```

某块板 FPGA 突然复位，复位后不能看到 High 就自行执行一次 ON_SEQUENCE。

规定：

```text
FPGA Reset
    |
    +--> 本板 EN 进入安全 OFF
    +--> 等待配置恢复有效
    +--> 即使 START_SYNC = High 也不自动上电
    +--> 等待下一次新的 Low -> High 边沿
```

这样避免单块板在其他板保持 ON 的情况下自行重新执行上电时序。

---

## 14. 各硬件通道最终可以这样理解

### START_SYNC

```text
单主推挽正常控制线
Board0 唯一输出，其余板输入

Low  : 全系统正常下电目标
High : 全系统正常上电目标
↑    : 20 板同时启动 ON_SEQUENCE
↓    : 20 板同时启动 OFF_SEQUENCE
```

### FAULT_REQ

```text
低速共享开漏线

High : Fault Bus 空闲，可以参与仲裁
Low  : 已有节点获得总线所有权

只负责：
仲裁 + BUSY
```

### FAULT_A/B

```text
专用 RS485 差分 Fault Bus

发送：
Fault Frame
+
20 个固定 ACK 时隙

任何时刻只有当前发送节点或当前 ACK 节点允许 DE=1
其余节点全部 DE=0
```

---

## 15. 一次完整工作过程

### 系统启动

```text
PC
 |
 +--> 主 RS485 配置各板 ON/OFF sequence
 +--> 主 RS485 配置各板 DUT mask
 +--> 逐板确认 READY
 |
 v
Board0: START_SYNC Low -> High
 |
 v
20 块板同步执行各自 ON_SEQUENCE
```

### 某个 DUT 运行中故障

```text
某一路电源 fault
 |
 v
本板立即关闭该 DUT
并锁存 fault inhibit
 |
 v
记录 pending fault
 |
 v
通过开漏 FAULT_REQ 按 Board ID 仲裁
 |
 v
获胜节点拉低 FAULT_REQ
 |
 v
打开本节点 RS485 Driver
通过 FAULT_A/B 发送 DUT fault
 |
 v
发送完成后释放 Driver
 |
 +----------+----------+----------+
 v          v          v          v
Board0    Board1      ...       Board19
收到合法帧后按本地 DUT mask 关闭该 DUT
 |
 v
20 个固定 ACK slot
各板只在自己的时隙短暂打开 Driver 回 ACK
 |
 v
发起方得到 ack_bitmap
 |
 +--> 全部 ACK：结束事务
 |
 +--> 缺 ACK：重发 / 重试
 |
 v
FAULT_REQ 释放
 |
 v
仍有 pending fault 的板卡重新参与下一轮仲裁
```

### 系统正常关闭

```text
Board0: START_SYNC High -> Low
 |
 v
20 块板同步执行各自 OFF_SEQUENCE
```

整个系统的核心思路是：

```text
正常动作按“整机”同步
故障动作按“DUT”隔离
FAULT_REQ 只负责仲裁
RS485 差分 Fault Bus 负责可靠高速传播
PC 负责配置
FPGA 负责实时执行
```
