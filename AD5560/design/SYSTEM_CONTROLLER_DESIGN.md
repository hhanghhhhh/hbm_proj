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

通信模块负责在此之前完成 Config RAM CRC 校验，只有校验通过才向 System Controller 发配置启动请求。System Controller 不接收也不判断 CRC 结果。

Config Manager 完成全部配置记录派发，并等待 8 个 Driver 全部恢复 `ready` 后返回 `cfg_done`。System Controller 收到 `cfg_done` 后进入 `ST_DRAIN`，确认模块停止、Driver空闲且无响应后进入 `READY`。

因此进入 `READY` 时，可以认为本轮配置涉及的最后一批 SPI / BUSY 事务已经全部结束。

### 3.2 Sequence

收到上位机开始上下电时序命令后：

```text
seq_start = 1 pulse
sel_id    = SEL_SEQUENCE
```

Power Sequence Engine 按时序产生寄存器写事务，直到 `seq_done`。

### 3.3 Alarm

任意 `ALARM[n]` 有效时，System Controller 锁存报警向量，停止当前 Config / Sequence，排空已提交事务后启动 `Alarm Handler`：

```text
ALARM
  ↓
锁存 alarm_vector
  ↓
abort 当前业务并关闭命令派发（保留旧 sel_id）
  ↓
等待模块停止、Driver全ready、响应消退
  ↓
切换 sel_id = SEL_ALARM，发 alarm_start
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

## 8. Driver资源池独占与安全释放

任意时刻只授权Config、Power或Alarm中的一个业务使用整个8BUS Driver资源池；同一业务内部8BUS继续独立并行。沿用 `sel_id`，没有跨业务rsp_owner队列或事务ID。

`ST_DRAIN` 保存 `drain_owner` 和 `drain_next`。正常cfg_done/seq_done/alarm_done/alarm_clear_done进入排空；整个排空期间 `sel_id` 保持旧owner，`o_cmd_enable=0`。Top同时门控公共cmd_valid及回送ready，避免模块误以为已提交被屏蔽的命令。

新增输入 `i_cfg_busy/i_seq_busy/i_alarm_busy`（Alarm的scan/clear busy合并）、`i_seq_read_pending[7:0]`、`i_driver_rsp_valid[7:0]`。释放须满足旧模块busy=0、Power pending=0、Driver ready=FF、原始rsp_valid=0，并连续两个采样沿确认。这样ready与rsp同拍恢复时仍由旧模块处理响应，不会转发给新业务。未来Measurement可复用“停止/暂停确认→排空→释放”的契约，本次不增加Measurement RTL或新的sel编码。

Alarm抢占Config/Power时先锁存向量，发单周期abort并进入排空，不启动Alarm。进入排空前采样沿可能仍有一笔valid&&ready，该事务已被Driver锁存，之后ready下降自然纳入屏障。进入排空后的abort沿Top禁止握手。旧业务收到abort后停止，不要求执行剩余记录或Step。旧读响应继续按旧sel路由，若业务已退出则丢弃；8路物理rsp都消退后再给Alarm授权并发start。排空期间新出现的报警BUS合并到锁存向量；正常完成排空期间的Alarm也优先处理。Alarm结束后不恢复被抢占业务。

`bus_fault`继续最高优先级，正常态和DRAIN均可立即进入FAULT，不以ready=FF为进入FAULT的前提；按旧owner发送abort并保留原Driver fault clear策略。FAULT_RESET_WAIT仅在显式fault_reset后等待所有Driver恢复、所有业务停止、pending清零及rsp消退，然后回IDLE。没有增加HW_INH或改变紧急硬件保护。
