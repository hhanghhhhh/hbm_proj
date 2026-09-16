# AD5560 Bus Worker 设计

## 1. 模块定位

`Bus Worker` 对应一条 AD5560 SPI BUS，负责本组 16 颗 AD5560 的寄存器事务执行。

上层只需要描述“访问哪颗器件、读写哪个寄存器、写入什么数据”，`Bus Worker` 负责完成对应的 AD5560 SPI 事务。

SPI 底层时序由通用 `SPI Master` 实现，`SPI Master` 支持常规 SPI 四种工作模式；AD5560 特有的器件选择、寄存器帧组织、读流程和 `BUSY` 处理均放在 `Bus Worker` 中。

---

## 2. 每个 Bus Worker 对应的硬件资源

每个实例固定对应一条 SPI BUS：

```text
Bus Worker n
├─ SPI BUS n
├─ 16 路独立 SYNC
├─ 1 路共享 BUSY
└─ 1 个 SPI Master
```

每次事务只允许选择一颗 AD5560。

---

## 3. 主要功能

### 3.1 器件选择

上层提供 `DEVICE_ID`，`Bus Worker` 根据该编号控制本组对应的 `SYNC`。

### 3.2 AD5560 寄存器写

上层提供：

```text
DEVICE_ID
REG_ADDR
REG_DATA
```

`Bus Worker` 负责组织 AD5560 的 24 bit SPI 写帧，并调用 `SPI Master` 完成发送。

### 3.3 AD5560 寄存器读

上层只发起一次寄存器读请求。

AD5560 读寄存器所需的多帧 SPI 操作由 `Bus Worker` 内部完成，最终向上层返回读取到的 `REG_DATA`。

上层模块不需要了解 AD5560 读操作的具体 SPI 帧流程。

### 3.4 BUSY 处理

每条 BUS 的 16 颗 AD5560 共用一根 `BUSY`，由对应 `Bus Worker` 直接检测。

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

上层到 `Bus Worker` 的事务接口暂按以下信息组织：

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

---

## 5. 多 BUS 选择与握手

8 个 `Bus Worker` 在顶层通过 `generate` 循环例化，每个实例具有固定的 `BUS_ID`。上层请求只需要输出一个 `bus_sel / BUS_ID`，顶层直接判断当前请求是否属于本实例，不再设置独立的 `Bus Command MUX` 模块。

典型选择逻辑：

```verilog
genvar bus_index;
generate
    for (bus_index = 0; bus_index < BUS_COUNT;
         bus_index = bus_index + 1) begin : g_ad5560_bus

        localparam [2:0] BUS_ID = bus_index;
        wire bus_selected;

        assign bus_selected = (bus_sel == BUS_ID);

        // 当前请求只有目标 BUS 的 Worker 能看到 valid
        assign worker_cmd_valid[bus_index] = cmd_valid && bus_selected;

        ...
    end
endgenerate
```

目标 BUS 的 `ready` 直接按 `bus_sel` 选择后回送给上层：

```verilog
assign selected_ready = worker_ready[bus_sel];
```

该方式与现有 `hbm_comm_top.v` 中多 BUS 实例的选择方式一致。

### 5.1 valid / ready 含义

当：

```text
cmd_valid && cmd_ready
```

同时为 1 时，本次命令完成握手，`Bus Worker` 锁存命令参数并开始执行。握手完成后，上层不需要继续保持本条命令。

`rsp_valid` 表示已经接受的事务真正执行完成：

### 5.2 并行工作方式

当前命令根据 `seq_bus_id` 选择目标 `Bus Worker`，并从该 Worker 取得 `seq_ready`。

只要当前命令完成 `valid / ready` 握手，就可以继续读取下一条时序命令，**不需要等待当前 Worker 的 `rsp_valid`**。

该结构的基本原则是：

```text
不同 BUS：事务可以重叠执行
同一 BUS：事务自动串行执行
```
