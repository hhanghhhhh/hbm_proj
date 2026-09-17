# AD5560 Command Arbiter 设计

## 1. 模块定位

`Command Arbiter` 是上层控制模块与 8 个 `AD5560 Driver` 之间的统一控制边界。

上层模块不直接连接各 Driver。前台寄存器事务、BUS 选择、读回数据以及 BUS 故障状态统一经过 `Command Arbiter`。

```text
Config Manager ───────┐
Power Sequence Engine ├──> Command Arbiter ───> AD5560 Driver × 8
Alarm Handler ────────┤
Runtime Control ──────┘
```

其中 `Alarm Handler`、`Runtime Control` 按实际需求增加。

---

## 2. 主要职责

第一版只负责：

- 在上层命令源之间选择当前命令；
- 根据 `BUS_ID` 将命令送到目标 Driver；
- 将目标 Driver 的 `ready` 返回给当前命令源；
- 对需要读回的命令返回 `rsp_valid / rsp_rd_data`；
- 汇总 8 个 Driver 的 `bus_fault`；
- 对上层同时提供总故障位和 8 bit BUS 故障向量。

不实现复杂公平仲裁、命令队列或乱序调度。

---

## 3. 上层命令接口

各命令源使用统一寄存器事务接口：

```text
cmd_valid
cmd_ready
cmd_bus_id[2:0]
cmd_rw
cmd_device_id[3:0]
cmd_reg_addr[6:0]
cmd_wr_data[15:0]
```

当：

```text
cmd_valid && cmd_ready
```

同时为 1 时，表示当前命令已经被目标 Driver 接收。

命令源随后即可继续处理下一条命令，不需要等待本次 SPI 事务真正完成。

因此 `Config Manager`、`Power Sequence Engine` 等纯写模块均按“握手即前进”工作。

---

## 4. BUS 选择

Arbiter 根据 `cmd_bus_id` 选择目标 Driver：

```text
driver_cmd_valid[n] = cmd_valid && (cmd_bus_id == n)
cmd_ready           = driver_cmd_ready[cmd_bus_id]
```

同一条命令只送到一个 Driver。

不同 BUS 已经完成握手的事务可以在 8 个 Driver 中并行执行；如果当前目标 Driver 忙，则其 `ready=0`，当前命令源保持本条命令等待。

---

## 5. BUS fault 汇总

每个 Driver 独立维护本 BUS 的故障状态。第一版主要故障来源为写事务 `BUSY timeout`。

8 路 Driver fault 输入 Arbiter：

```text
driver_bus_fault[7:0]
```

Arbiter 输出：

```text
bus_fault             // 任意 BUS 故障
bus_fault_vector[7:0] // 各 BUS 独立故障状态
```

逻辑关系：

```verilog
assign bus_fault_vector = driver_bus_fault;
assign bus_fault = |driver_bus_fault;
```

Arbiter 只负责汇总，不重复锁存故障；故障状态由对应 Driver 保存。

不同上层模块可按需要使用：

```text
Config Manager        -> bus_fault，任意 BUS 故障时停止剩余配置
Power Sequence Engine -> bus_fault，系统级故障策略使用
故障管理 / 上位机状态 -> bus_fault_vector[7:0] 定位具体 BUS
```

---

## 6. 读事务返回

`Config Manager` 和正常 Power Sequence 主要产生写事务，不依赖逐条完成响应。

后续 `Alarm Handler` 或其他运行期控制模块需要读寄存器时，Driver 返回：

```text
rsp_valid
rsp_rd_data[15:0]
```

`Command Arbiter` 将目标 Driver 的读回结果返回给发起该读命令的上层模块。

第一版可限制需要读回的数据访问按顺序执行，不引入多个未完成读事务的复杂匹配机制。

---

## 7. 与 Driver 的边界

```text
Command Arbiter
      │
      ├─ valid / ready
      ├─ RW / DEVICE_ID / REG_ADDR / WR_DATA
      └─ BUS_ID 选择
      │
      ▼
AD5560 Driver × 8
      │
      ├─ rsp_valid / rsp_rd_data
      └─ bus_fault
      │
      ▼
SPI Master × 8
```

Driver 在 `valid && ready` 时锁存命令参数，因此握手后 Arbiter 可以立即切换到下一条命令。