# AD5560 System Controller 设计

## 1. 模块定位

`System Controller` 是 AD5560 子系统的顶层控制状态机，负责业务模块选择、系统流程控制以及系统级故障处理。

---

## 2. 主要职责

第一版负责：

- 根据上位机命令控制 `Config Manager` 和 `Power Sequence Engine` 启动；
- 接收 `ALARM[7:0]`，锁存报警 BUS 并启动 `Alarm Handler`；
- 根据当前系统状态产生 `sel_id`，选择当前业务模块；
- 接收 8 路 Driver `bus_fault`，锁存系统 fault 信息；
- fault 锁存完成后清除 Driver 内部 sticky `bus_fault`；
- fault 发生时停止当前 Config / Sequence，并进入 `FAULT` 状态。

System Controller 不负责 8 条 BUS 的仲裁或 Driver 选择。当前被选中的业务模块自行输出 `BUS_ID`，顶层公共命令通路根据该 `BUS_ID` 路由到对应 Driver。

第一版不实现复杂公平仲裁、命令队列或乱序调度。

---

## 3. 系统状态

### 3.1 Config

收到上位机配置启动命令后：

```text
cfg_start = 1 pulse
sel_id    = SEL_CONFIG
```

Config Manager 完成全部配置记录派发并返回 `cfg_done` 后进入 `READY`。

### 3.2 Sequence

收到上位机开始上下电时序命令后：

```text
seq_start = 1 pulse
sel_id    = SEL_SEQUENCE
```

Power Sequence Engine 按时序产生寄存器写事务，直到 `seq_done`。

### 3.3 Alarm

任意 `ALARM[n]` 有效时，System Controller 先锁存报警向量，再启动 `Alarm Handler`：

```text
alarm_latch[7:0] <- ALARM[7:0]
alarm_start      = 1 pulse
sel_id           = SEL_ALARM
```

已经被 Driver 接受的 SPI 事务不取消。Alarm Handler 输出自己的 `BUS_ID` 和读命令，通过统一命令通路访问对应 BUS 的 Alarm / Fault Status 寄存器。

Alarm 处理期间不再向 Power Sequence Engine 或 Config Manager 返回命令 `ready`，因此它们不会继续派发新事务。`alarm_done` 后若没有系统 fault，再返回被 Alarm 打断前的正常状态。

---

## 6. bus_fault 处理

每个 Driver 独立输出 sticky：

```text
driver_bus_fault[7:0]
```

第一版主要来源为 AD5560 `BUSY timeout`。

System Controller 检测到任意 fault 后：

```text
1. 锁存 fault_vector_latched[7:0]
2. 停止当前 Config / Sequence
3. 进入 FAULT 状态
4. 锁存完成后向对应 Driver 发 bus_fault_clear 脉冲
```

建议保留完整 8 bit 向量：

```text
fault_vector_latched[7:0]
```

如上位机接口需要单个 `fault_id`，可由该向量编码得到；系统内部不只保存单个 ID，以避免同时多 BUS fault 时丢失信息。

Driver fault clear：

```text
driver_fault_clear[7:0]
```

只用于清除 Driver 内部 sticky fault。**清除 Driver fault 不代表系统故障恢复。**

System Controller 自己锁存的 `fault_vector_latched` 在 `FAULT` 状态继续保留，直到收到上位机明确的故障复位 / 重新启动命令。

fault 发生时应同时向正在运行的功能模块发出：

```text
cfg_abort
seq_abort
```

防止模块停留在 busy 状态或后续自动继续执行。

---

## 7. Alarm 与 bus_fault 的区别

`ALARM` 是 AD5560 的器件状态事件，需要通过 `Alarm Handler` 读取状态寄存器进行定位。

`bus_fault` 表示 FPGA 无法正常完成某条 BUS 上的寄存器事务，第一版主要是 `BUSY timeout`，属于系统执行异常。

因此第一版优先级为：

```text
bus_fault > ALARM > 当前正常工作状态
```

- `ALARM`：进入 Alarm Handler，读取状态后再决定后续策略；
- `bus_fault`：直接停止 Config / Sequence，进入 `FAULT`。
