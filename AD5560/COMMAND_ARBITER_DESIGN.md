# AD5560 Command Arbiter 设计

## 1. 模块定位

`Command Arbiter` 是上层控制模块与 8 个 `Bus Service` 之间的统一边界。

上层模块不直接连接各 `Bus Service`。前台寄存器事务、BUS 选择以及 BUS 故障状态统一经过 `Command Arbiter`。

```text
Config Manager ───────┐
Power Sequence Engine ├──> Command Arbiter ───> Bus Service × 8
Runtime Control       ┘        （后续按需增加）
```

后台 Telemetry 仍由各 `Bus Service` 内部自行调度，不参与前台命令仲裁。

---

## 2. 主要职责

`Command Arbiter` 第一版只负责以下功能：

- 在多个前台命令源之间选择当前命令；
- 根据 `BUS_ID` 将命令送到目标 `Bus Service`；
- 将目标 Service 的 `ready` 返回给当前命令源；
- 汇总 8 个 `Bus Service` 的故障状态；
- 对上层同时提供总故障位和 8 bit BUS 故障向量。

第一版不实现复杂公平仲裁、命令队列或乱序调度。

---

## 3. 前台命令接口

各命令源使用统一的寄存器事务接口：

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

同时为 1 时，表示当前命令已经被目标 `Bus Service` 接收。命令源随后即可继续处理下一条命令，不需要等待本次 SPI 事务真正执行完成。

`Config Manager` 第一版只产生写命令，因此其 `cmd_rw` 固定为写。

---

## 4. BUS 选择

`Command Arbiter` 根据当前命令的 `BUS_ID` 选择目标 `Bus Service`。

逻辑保持简单：

```text
service_cmd_valid[n] = cmd_valid && (cmd_bus_id == n)
cmd_ready            = service_cmd_ready[cmd_bus_id]
```

同一时刻只向一条 `Bus Service` 转发当前前台命令。

不同 BUS 已经接受的事务可以在各自 Service / Driver 中并行执行。

---

## 5. BUS fault 汇总

每个 `Bus Service` 独立维护本 BUS 的故障状态，例如 Driver 检测到 `BUSY timeout` 后置位本 BUS 的 `bus_fault`。

8 路 Service fault 汇总到 `Command Arbiter`：

```text
service_bus_fault[7:0]
```

Arbiter 对上层同时输出：

```text
bus_fault            // 任意 BUS 故障
bus_fault_vector[7:0] // 各 BUS 独立故障状态
```

逻辑关系：

```verilog
assign bus_fault_vector = service_bus_fault;
assign bus_fault = |service_bus_fault;
```

`Command Arbiter` 只负责汇总，不负责锁存故障。故障锁存由对应 `Bus Service` 完成。

这样不同上层模块可以按需求选择使用：

```text
Config Manager       -> 只使用 bus_fault，任意 BUS 故障即停止剩余配置
Power Sequence Engine-> 可使用 bus_fault，任意 BUS 故障时停止当前时序
状态 / 故障管理模块 -> 使用 bus_fault_vector 判断具体故障 BUS
```

---

## 6. 与 Bus Service 的边界

每个 `Bus Service` 对外的前台控制和故障状态统一连接到 `Command Arbiter`。

```text
Command Arbiter
      │
      ├─ command / ready
      ├─ BUS_ID 选择
      └─ bus_fault 汇总
      │
      ▼
Bus Service × 8
      │
      ▼
AD5560 Driver
```

`Bus Service` 内部仍负责：

- 前台命令优先于后台 Telemetry；
- 一条 BUS 内的事务串行执行；
- Driver 调用；
- Telemetry 轮询和 Telemetry RAM 更新；
- 本 BUS 故障状态维护。

---

## 7. 读事务返回

第一版 `Config Manager` 和 `Power Sequence Engine` 均不依赖逐条事务返回结果。

后续如果增加需要主动读寄存器的 `Runtime Control`，可由 `Command Arbiter` 将目标 `Bus Service` 的读回数据返回给当前命令源。该功能不改变现有前台命令和 fault 汇总结构。
