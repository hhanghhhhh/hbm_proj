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

Config Manager 完成全部配置记录派发，并等待 8 个 Driver 全部恢复 `ready` 后返回 `cfg_done`。System Controller 收到该 `cfg_done` 后进入 `READY`。

因此进入 `READY` 时，可以认为本轮配置涉及的最后一批 SPI / BUSY 事务已经全部结束。

### 3.2 Sequence

收到上位机开始上下电时序命令后：

```text
seq_start = 1 pulse
sel_id    = SEL_SEQUENCE
```

Power Sequence Engine 按时序产生寄存器写事务，直到 `seq_done`。

### 3.3 Alarm

任意 `ALARM[n]` 有效时，System Controller 锁存报警向量，终止当前 Config / Sequence，并启动 `Alarm Handler`：

```text
ALARM
  ↓
锁存 alarm_vector
  ↓
abort 当前业务
  ↓
Alarm Handler 扫描并定位故障 Device
  ↓
alarm_done
  ↓
进入 FAULT_HANDLE
```

Alarm 扫描阶段只读取状态，不清除 Alarm。

进入 `FAULT_HANDLE` 后根据实际故障执行后续处理；具体处理策略后续确定。故障处理完成后，再单独启动 Alarm Clear。

Alarm 发生后不恢复被中断的 Config / Power Sequence。

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

System Controller 自己锁存的 `fault_vector_latched` 在 `FAULT` 状态继续保留。

系统故障恢复使用独立 `fault_reset` 命令，仅在 `FAULT` 状态有效：

```text
fault_reset
  ↓
等待全部 Driver ready
  ↓
清除 fault_vector_latched
  ↓
进入 IDLE
```

恢复后不直接进入 `READY`，也不自动继续故障前的 Config / Sequence；后续流程由上位机重新发起。

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
