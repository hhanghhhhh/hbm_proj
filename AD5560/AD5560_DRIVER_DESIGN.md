# AD5560 Driver 设计

## 1. 模块定位

`AD5560 Driver` 对应一条 AD5560 SPI BUS，负责本组 16 颗 AD5560 的寄存器事务执行。

上层只需要描述“访问哪颗器件、读写哪个寄存器、写入什么数据”，`AD5560 Driver` 负责完成对应的 AD5560 SPI 事务。

SPI 底层时序由通用 `SPI Master` 实现，`SPI Master` 支持常规 SPI 四种工作模式；AD5560 特有的器件选择、寄存器帧组织、读流程和 `BUSY` 处理均放在 `AD5560 Driver` 中。

`AD5560 Driver` 不负责配置表管理、上下电时序调度、BUS 选择或后台遥测轮询。

---

## 2. 每个 AD5560 Driver 对应的硬件资源

每个实例固定对应一条 SPI BUS：

```text
AD5560 Driver n
├─ SPI BUS n
├─ 16 路独立 SYNC
├─ 1 路共享 BUSY
└─ 1 个 SPI Master
```

每次事务只允许选择一颗 AD5560。

---

## 3. 主要功能

### 3.1 器件选择

上层提供 `DEVICE_ID`，`AD5560 Driver` 根据该编号控制本组对应的 `SYNC`。

### 3.2 AD5560 寄存器写

上层提供：

```text
DEVICE_ID
REG_ADDR
REG_DATA
```

`AD5560 Driver` 负责组织 AD5560 的 24 bit SPI 写帧，并调用 `SPI Master` 完成发送。

### 3.3 AD5560 寄存器读

上层只发起一次寄存器读请求。

AD5560 读寄存器所需的多帧 SPI 操作由 `AD5560 Driver` 内部完成，最终向上层返回读取到的 `REG_DATA`。

上层模块不需要了解 AD5560 读操作的具体 SPI 帧流程。

### 3.4 BUSY 处理

每条 BUS 的 16 颗 AD5560 共用一根 `BUSY`，由对应 `AD5560 Driver` 直接检测。

基本事务流程：

```text
接收寄存器事务
    ↓
确认 BUSY 已释放
    ↓
选择 DEVICE / 控制 SYNC
    ↓
执行 SPI transaction
    ↓
等待 BUSY 释放
    ↓
返回事务完成
```

`BUSY` 等待需要设置 timeout，避免器件异常导致上层流程永久阻塞。

---

## 4. 初步接口

`Bus Service` 到 `AD5560 Driver` 的事务接口暂按以下信息组织：

```text
cmd_valid
cmd_ready
cmd_rw
cmd_device_id[3:0]
cmd_reg_addr[6:0]
cmd_wr_data[15:0]
```

返回接口暂按：

```text
rsp_valid
rsp_rd_data[15:0]
rsp_error
```

其中：

- `cmd_rw` 区分寄存器读 / 写；
- 写操作使用 `cmd_wr_data`；
- 读操作完成后通过 `rsp_rd_data` 返回结果；
- `rsp_error` 用于返回 BUSY timeout 等事务异常。

当：

```text
cmd_valid && cmd_ready
```

同时为 1 时，本次事务完成握手，Driver 锁存命令参数并开始执行。握手后上层不需要继续保持本条命令。

`rsp_valid` 表示已经接受的寄存器事务真正执行完成。

---

## 5. 与 Bus Service 的关系

每条 BUS 设置一个 `Bus Service`，`AD5560 Driver` 作为该 Service 的下层寄存器访问执行器。

```text
Bus Service
├─ 接收前台寄存器事务
├─ 空闲时发起后台遥测事务
├─ 维护本 BUS Telemetry RAM
│
└─ AD5560 Driver
      └─ SPI Master
```

`Bus Service` 决定“下一笔执行什么事务”，`AD5560 Driver` 只负责“把这一笔寄存器事务执行完成”。

前台任务优先于后台遥测。Driver 忙时 Service 不再向其提交新事务；Driver 完成后 Service 再决定下一笔任务来源。

---

## 6. 多 BUS 选择与并行工作

BUS 选择不在 `AD5560 Driver` 内实现。8 个 `Bus Service` 在顶层通过 `generate` 循环例化，每个实例具有固定 `BUS_ID`。

典型选择逻辑：

```verilog
genvar bus_index;
generate
    for (bus_index = 0; bus_index < BUS_COUNT;
         bus_index = bus_index + 1) begin : g_ad5560_bus

        localparam [2:0] BUS_ID = bus_index;
        wire bus_selected;

        assign bus_selected = (bus_sel == BUS_ID);
        assign service_cmd_valid[bus_index] = cmd_valid && bus_selected;

        ...
    end
endgenerate
```

目标 BUS 的 `ready` 按 `bus_sel` 选择后回送给上层：

```verilog
assign selected_ready = service_ready[bus_sel];
```

对于 `Power Sequence Engine`，当前记录与目标 `Bus Service` 完成 `valid / ready` 握手后即可继续读取下一条记录，不等待本条事务对应的 Driver `rsp_valid`。

因此：

```text
不同 BUS：事务可以重叠执行
同一 BUS：通过本 BUS Service / Driver 自动串行
```

例如 BUS0 已经接受一条事务并进入工作状态后，下一条记录如果目标为 BUS3，只要 BUS3 Service 为 ready，就可以立即完成握手并启动 BUS3。这样多个 SPI BUS 可以同时处于工作状态，而上层仍保持单路 `bus_sel + valid / ready` 接口。
