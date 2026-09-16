# AD5560 Bus Service 设计

## 1. 模块定位

每条 SPI BUS 设置一个 `Bus Service`。

`Bus Service` 负责本 BUS 的任务调度：

- 接收上层前台寄存器事务；
- 总线空闲时执行后台遥测轮询；
- 管理本 BUS 的 `Telemetry RAM`；
- 向下调用 `AD5560 Driver` 完成实际寄存器读写。

```text
Bus Service
├─ Foreground Command
├─ Telemetry Scheduler
├─ Telemetry RAM
│
└─ AD5560 Driver
      └─ SPI Master
```

---

## 2. 任务优先级

本 BUS 的调度优先级固定为：

```text
前台寄存器事务 > 后台 Telemetry
```

当存在前台请求时，优先提交给 `AD5560 Driver`。

只有当前没有待执行前台请求，并且本 Service 当前没有未完成的 Driver 事务时，才允许发起后台遥测。

后台遥测以**单次寄存器读**为最小调度单位。完成一个遥测寄存器读取后，重新检查前台请求；如果此时出现前台请求，应先执行前台事务，再继续遥测。

已经通过 `drv_start` 启动的单次遥测读不在中途取消，前台请求等待当前这笔寄存器事务完成即可。

---

## 3. 前台事务接口

上层向 `Bus Service` 提交统一格式的 AD5560 寄存器事务：

```text
cmd_valid
cmd_ready
cmd_rw
cmd_device_id[3:0]
cmd_reg_addr[6:0]
cmd_wr_data[15:0]
```

返回接口：

```text
rsp_valid
rsp_rd_data[15:0]
rsp_error
```

当：

```text
cmd_valid && cmd_ready
```

同时为 1 时，表示本条前台命令已经被本 BUS 接收。之后上层不需要继续保持该命令。

由于 Driver 内部不再锁存命令参数，`Bus Service` 在接收前台命令后负责保存本条事务参数，并在 Driver 执行期间保持 Driver 输入不变。

`rsp_valid` 表示该寄存器事务已经由下层 `AD5560 Driver` 真正执行完成。

---

## 4. Telemetry 控制

每个 `Bus Service` 提供：

```text
telemetry_enable
telemetry_mask[15:0]
```

行为定义：

- `telemetry_enable = 0`：不再发起新的后台遥测事务；
- `telemetry_enable = 1`：循环扫描本 BUS 的 16 颗 AD5560；
- 仅轮询 `telemetry_mask[n] = 1` 的器件；
- `telemetry_mask[n] = 0` 的器件直接跳过。

典型使用方式：

```text
配置阶段：telemetry_enable = 0
上电运行后：telemetry_enable = 1
```

`telemetry_enable` 或 `telemetry_mask` 改变时，不强制中断已经启动的当前遥测事务，新配置从下一次调度开始生效。

---

## 5. Telemetry 轮询

当前先按每颗器件周期读取以下状态考虑：

```text
Voltage
Current
Alarm / Fault Status
```

具体寄存器地址后续确定。

轮询过程例如：

```text
DEV n Voltage
    ↓
重新检查前台请求
    ↓
DEV n Current
    ↓
重新检查前台请求
    ↓
DEV n Alarm
    ↓
重新检查前台请求
    ↓
寻找下一颗 mask = 1 的 DEVICE
```

轮询到 DEV15 后重新从 DEV0 开始。

---

## 6. Telemetry RAM

每条 BUS 独立设置一块 `Telemetry RAM`，共 8 块。

Telemetry RAM 只保存**最新状态**，不保存历史数据。新的遥测结果直接覆盖同一地址中的旧值，上位机读取 RAM 即可获得最近一次采样结果。

地址可按以下逻辑组织：

```text
DEVICE_ID + TELEMETRY_ITEM
```

例如：

```text
ITEM 0：Voltage
ITEM 1：Current
ITEM 2：Alarm / Fault Status
```

具体 RAM 位宽和数据格式后续根据实际遥测寄存器确定。

Telemetry RAM 建议使用双口 RAM：

- A 口由 `Bus Service` 写入最新遥测值；
- B 口供上位机通信侧读取。

因此后台刷新和上位机读取可以同时进行，不需要额外读写仲裁。同地址同时读写时允许读到更新前或更新后的值，第一版不做严格原子快照。

---

## 7. 与 AD5560 Driver 的接口

`Bus Service` 与 `AD5560 Driver` 为一对一关系，内部不再使用第二套 `valid / ready` 握手，采用简单的 `start / done` 脉冲接口。

Service 到 Driver：

```text
drv_start              // 单 clk 脉冲
drv_rw
drv_device_id[3:0]
drv_reg_addr[6:0]
drv_wr_data[15:0]
```

Driver 返回：

```text
drv_done               // 单 clk 脉冲
drv_rd_data[15:0]
drv_error
```

使用规则：

```text
Service 准备好 Driver 参数
    ↓
drv_start 拉高 1 clk
    ↓
Service 保持 drv_rw / device_id / reg_addr / wr_data 不变
    ↓
等待 drv_done
    ↓
处理读回数据或错误
    ↓
再决定下一笔前台 / Telemetry 事务
```

`Bus Service` 自己记录当前是否存在未完成 Driver 事务，因此 Driver 不需要再提供 `ready / busy`。

前台事务参数由 Service 在外层 `cmd_valid && cmd_ready` 时接收并保存；后台遥测参数则由 Service 自己产生。无论来源是哪一种，一旦发出 `drv_start`，在 `drv_done` 之前都保持 Driver 输入接口不变。

`Bus Service` 不区分 Driver 内部的一帧写事务或两帧 readback，只等待最终 `drv_done`。

---

## 8. 多 BUS 工作方式

8 个 `Bus Service` 相互独立，每个 Service 只管理自己的 SPI BUS、Driver 和 Telemetry RAM。

因此可以出现：

```text
BUS0：执行 Power Sequence 前台命令
BUS1：执行后台 Telemetry
BUS2：空闲
BUS3：执行前台寄存器配置
...
```

不同 BUS 可以同时工作；同一 BUS 内由对应 `Bus Service` 保证事务串行执行。

顶层仍通过固定 `BUS_ID` 对 8 个 Service 做选择，上层不需要为后台遥测增加额外的全局仲裁模块。
