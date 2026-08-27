# 多板卡 DUT 电源控制整体流程说明

> 本文用于说明整个多板卡电源控制系统如何工作，重点解释三根硬件线分别做什么，以及正常上电、正常下电、故障关断时各模块之间如何配合。
>
> 具体协议参数和 RTL 约束以 `DUT_POWER_CONTROL.md` 为准。

## 1. 系统要解决的问题

系统共有 20 块板卡，每块板控制 128 路 EN。

一个 DUT 的多路电源可能分散在不同板卡，因此需要同时解决两个问题：

1. 正常上电/下电时，20 块板卡要在同一个时间起点执行各自的 EN 时序；
2. 任意一路电源故障时，要把该 DUT 分散在所有板卡上的电源都关掉，但不能影响其他 DUT。

PC 通过 RS485 管理整个系统，但 PC 不能承担实时故障保护，因此实时同步和故障传播都由 FPGA 之间完成。

---

## 2. 整体架构

```text
                          PC Master
                             |
                             | RS485
                             | 配置 / 查询 / READY / 故障清除
                             v
        +--------------------+--------------------+
        |                    |                    |
      Board0               Board1              Board19
        |                    |                    |
        |<-------------- START_SYNC ------------>|
        |<-------------- FAULT_REQ ------------->|
        |<-------------- FAULT_IO -------------->|
        |                    |                    |
     128 x EN             128 x EN             128 x EN
```

三根硬件线分工非常明确：

```text
START_SYNC : 正常全系统上/下电同步
FAULT_REQ  : 故障总线仲裁 + BUSY
FAULT_IO   : 故障数据 + ACK
```

RS485 不承担实时同步和实时故障传播。

---

## 3. 每块板内部保存什么

每块板主要保存两类数据。

### 3.1 正常上/下电时序

每块板保存本板 128 路 EN 的：

```text
ON_SEQUENCE
OFF_SEQUENCE
```

它描述的是本板 128 路 EN 的正常动作顺序，不按 DUT 划分。

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

这个 mask 不用于正常上电顺序，主要用于 DUT 故障时的快速关断。

---

## 4. START_SYNC 是干什么的

`START_SYNC` 是一个持续电平信号：

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

### 正常上电时序

```text
PC
 |
 | RS485 下发各板 ON_SEQUENCE / OFF_SEQUENCE
 v
20 块板保存配置
 |
 | PC 逐板查询
 v
所有板 READY
 |
 | 指定控制节点
 v
START_SYNC : Low -> High
 |
 +----------+----------+----------+
 v          v          v          v
Board0    Board1      ...       Board19
ON_SEQ    ON_SEQ                ON_SEQ
T=0       T=0                   T=0
```

PC 不需要按照实时顺序一块一块控制 EN，只需要提前把 sequence 配好。

### 正常下电时序

```text
START_SYNC : High -> Low
 |
 +----------+----------+----------+
 v          v          v          v
Board0    Board1      ...       Board19
OFF_SEQ   OFF_SEQ               OFF_SEQ
T=0       T=0                   T=0
```

正常下电仍然按照预配置的下电顺序执行。

---

## 5. 为什么 START_SYNC 不区分 DUT

当前系统的正常运行方式是所有 DUT 一起上电、一起下电。

因此如果让 `START_SYNC` 携带 DUT 含义，反而会增加不必要的复杂度，而且只有一根线也无法表达多个 DUT 的独立启动状态。

所以正常控制采用：

```text
整个系统一起 ON / OFF
```

而 DUT 维度只保留在故障保护中：

```text
某个 DUT fault -> 只 KILL 这个 DUT
```

两种控制逻辑互不混淆。

---

## 6. DUT 故障时发生什么

假设 Board7 的某一路 EN 发生故障，并确定它属于 DUT3。

第一步永远是本板立即关断，不等待任何通信：

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

然后 Board7 才去竞争 Fault Bus，把 `KILL DUT3` 告诉其他板卡。

---

## 7. FAULT_REQ 是干什么的

`FAULT_REQ` 不传数据，它只表示 Fault Bus 是否被某个节点占用：

```text
High = Fault Bus 空闲
Low  = 某块板已经获得 Fault Bus 所有权
```

如果多个板同时发生故障，各板先按照 Board ID 对应的固定等待时隙竞争。

```text
FAULT_REQ = High
      |
      +--> ARB_GUARD
      |
      +--> Board0 竞争时刻
      +--> Board1 竞争时刻
      +--> ...
      +--> Board19 竞争时刻
```

某块板到达自己的竞争时刻时，如果 `FAULT_REQ` 仍然是 High，就拉 Low，表示：

```text
“本次 Fault Bus 由我使用”
```

其他板一看到 `FAULT_REQ = Low`：

```text
仲裁计数清零
保留自己的 pending fault
等待当前事务结束
```

当前事务结束后 `FAULT_REQ` 回到 High，仍有 pending fault 的板卡重新参与下一轮仲裁。

因此同一块板同时出现多个 DUT fault，也是一次发送一个，之后重新参加下一轮。

---

## 8. FAULT_IO 是干什么的

取得 Fault Bus 所有权的板通过 `FAULT_IO` 发送一个固定长度故障帧。

帧中包含：

```text
SOF
SOURCE_ID
DUT_ID
FAULT_CODE
EVENT_ID
CRC16
```

例如：

```text
Board7 -> 全部板卡：
DUT3 fault，请执行 DUT3 KILL
```

所有板卡一直监听 `FAULT_IO`。

某块板收到完整合法帧以后：

```text
DUT_ID = 3
     |
     +--> 查本板 DUT3_MASK
     |
     +--> 本板 DUT3 对应 EN 立即关闭
     |
     +--> 锁存 DUT3 fault inhibit
     |
     +--> 等待自己的 ACK slot
```

如果本板 DUT3 mask 为 0，也要 ACK，表示自己正确收到并处理了这个事件。

---

## 9. ACK 是怎么工作的

不能让 20 块板同时 ACK，否则线路上的响应无法区分是谁发的。

因此每个 Board ID 有一个固定 ACK 时隙：

```text
Fault Frame
    |
    +--> Turnaround Gap
    |
    +--> ACK Board0
    +--> ACK Board1
    +--> ...
    +--> ACK Board19
```

每块板只在自己的时隙内把 `FAULT_IO` 拉 Low。

发送方最终得到：

```text
ack_bitmap[19:0]
```

如果全部收到：

```text
事务完成
FAULT_REQ -> High
```

如果某些板没 ACK：

```text
保持 FAULT_REQ = Low
重新发送同一个 EVENT_ID
再次等待 ACK
```

首次失败后最多重发 2 次。

如果仍有节点失败：

```text
记录 missing ACK bitmap
释放 FAULT_REQ
```

不能因为一个坏节点把整个 Fault Bus 永久堵死。

---

## 10. START_SYNC 和 Fault 谁优先

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

概念上可以理解为：

```text
normal_sequence_en
       |
       v
   AND NOT fault_inhibit_mask
       |
       v
    actual EN
```

因此可能出现正常且允许的系统状态：

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

## 11. FPGA 复位时如何处理

如果系统已经上电：

```text
START_SYNC = High
```

某块板 FPGA 突然复位，复位后不能看到 High 就自行执行一次 ON_SEQUENCE。

原因是其他板卡可能一直处于 ON 状态，如果单块板自行重新上电，就无法保证跨板时序关系。

因此规定：

```text
FPGA Reset
    |
    +--> 本板 EN 进入安全 OFF
    +--> 等待配置恢复有效
    +--> 即使 START_SYNC = High 也不自动上电
    +--> 等待下一次新的 Low -> High 边沿
```

也就是说这种异常需要重新执行一次全系统正常 power cycle 才恢复。

---

## 12. 三根线最终可以这样理解

### START_SYNC

```text
正常控制线

Low  : 全系统正常下电目标
High : 全系统正常上电目标
↑    : 20 板同时启动 ON_SEQUENCE
↓    : 20 板同时启动 OFF_SEQUENCE
```

### FAULT_REQ

```text
Fault Bus 所有权 / BUSY 线

High : 总线空闲，可以参与仲裁
Low  : 已有节点正在处理 Fault transaction
```

### FAULT_IO

```text
Fault Bus 数据线

发送 KILL DUT_ID 等故障信息
+
事务结束后复用为 20 个固定时隙 ACK
```

---

## 13. 一次完整工作过程

### 系统启动

```text
PC
 |
 +--> RS485 配置各板 ON/OFF sequence
 +--> RS485 配置各板 DUT mask
 +--> 逐板确认 READY
 |
 v
START_SYNC Low -> High
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
 |
 v
记录 pending fault
 |
 v
FAULT_REQ 仲裁
 |
 v
获胜节点拉低 FAULT_REQ
 |
 v
FAULT_IO 发送 DUT fault
 |
 +----------+----------+----------+
 v          v          v          v
Board0    Board1      ...       Board19
按本地 DUT mask 关闭该 DUT
 |
 v
20 个固定 ACK slot
 |
 v
全部 ACK 或完成重试
 |
 v
FAULT_REQ 释放
```

### 系统正常关闭

```text
START_SYNC High -> Low
 |
 v
20 块板同步执行各自 OFF_SEQUENCE
```

整个系统的核心思路就是：

```text
正常动作按“整机”同步
故障动作按“DUT”隔离
PC 负责配置
FPGA 负责实时执行
```
